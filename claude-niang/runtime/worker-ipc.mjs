// Worker side of the pipe (the client is requestPipeRefresh in shared.mjs). The
// pipe crosses per-process filesystem views while keeping a single writer, and
// it accepts only a fresh read-only usage request, never arbitrary commands.
export function createPipeRefreshHandler(enqueue){
  const pending=new Map();
  return {
    onConnection(socket){
      let buffer='',accepted=false,id;
      socket.setEncoding('utf8');
      socket.on('error',()=>{});socket.setTimeout(100000,()=>socket.destroy());
      socket.on('close',()=>{if(id&&pending.get(id)===socket)pending.delete(id);});
      socket.on('data',chunk=>{
        if(accepted)return;
        buffer+=chunk.toString('utf8');if(buffer.length>4096){socket.destroy();return;}
        const end=buffer.indexOf('\n');if(end<0)return;
        let request;try{request=JSON.parse(buffer.slice(0,end));}catch{socket.destroy();return;}
        if(request?.method!=='refresh'||typeof request.id!=='string'||!/^[0-9a-f-]{36}$/i.test(request.id)||pending.size>=64||pending.has(request.id)){socket.destroy();return;}
        accepted=true;id=request.id;pending.set(id,socket);enqueue();
      });
    },
    takeBatch(){const batch=[...pending];pending.clear();return batch;},
    complete(batch,snapshot){for(const [id,socket] of batch)if(!socket.destroyed)socket.end(JSON.stringify({requestId:id,snapshot})+'\n');},
    // Release claimed clients too: they are no longer in the pending map.
    // An empty disconnect makes the client use its filesystem fallback.
    fail(batch){for(const [,socket] of batch)if(!socket.destroyed&&!socket.writableEnded)socket.destroy();},
    get pendingCount(){return pending.size;}
  };
}
