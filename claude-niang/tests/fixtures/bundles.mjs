// Realistic claude.ai answers (shapes as of 2026) wrapped the way
// runtime/claude-browser.ps1 reports them.
export const ORG_MAX='1b2c3d4e-0000-4000-8000-000000000001';
export const ORG_TEAM='1b2c3d4e-0000-4000-8000-000000000002';
export const orgs=[
  {uuid:ORG_MAX,name:"Personal Organization",capabilities:['chat','claude_max'],rate_limit_tier:'default_claude_max_20x',raven_type:null,billing_type:'stripe_subscription'},
  {uuid:ORG_TEAM,name:'Acme Team',capabilities:['chat','raven'],rate_limit_tier:'default_raven',raven_type:'team'}
];
export const usageOld={
  five_hour:{utilization:37.0,resets_at:'2026-10-26T09:00:00.123456+00:00'},
  seven_day:{utilization:12.5,resets_at:'2026-10-30T01:00:00+00:00'},
  seven_day_opus:{utilization:3,resets_at:null},
  seven_day_sonnet:null,
  seven_day_oauth_apps:null,
  extra_usage:{is_enabled:true,monthly_limit:2000,used_credits:770,utilization:38.5}
};
export const usageNew={
  limits:[
    {kind:'session',percent:12,resets_at:'2026-10-26T09:00:00Z'},
    {kind:'weekly_all',percent:40,resets_at:'2026-10-30T01:00:00Z'},
    {kind:'weekly_scoped',percent:55,resets_at:'2026-10-30T01:00:00Z',scope:{model:{display_name:'Fable'}}}
  ],
  spend:{enabled:true,limit:{amount_minor:5000,currency:'USD'},used:{amount_minor:1250}}
};
export const usageFree={five_hour:null,seven_day:null,seven_day_opus:null,limits:[]};
export function request(url,status,body,{contentType='application/json',cf='',retryAfter='',encoding='text',error=''}={}) {
  const text=typeof body==='string'?body:JSON.stringify(body);
  return {url,status,contentType,cfMitigated:cf,retryAfter,body:encoding==='json-string'?JSON.stringify(text):text,bodyEncoding:encoding,error};
}
export function bundle({usage=usageOld,orgList=orgs,selected=ORG_MAX,session=true,credits=null,extra={}}={}) {
  const requests={};
  if(session){
    requests.organizations=request('https://claude.ai/api/organizations',200,orgList);
    if(usage!==undefined && usage!==null)requests.usage=request('https://claude.ai/api/organizations/'+selected+'/usage',200,usage);
    if(credits)requests.credits=request('https://claude.ai/api/organizations/'+selected+'/prepaid/credits',200,credits);
  }
  return {v:1,mode:'fetch',ok:true,runtimeVersion:'141.0.3537.71',session:{hasSessionCookie:session,lastActiveOrg:selected},selectedOrg:selected,requests,...extra};
}
export const challengeHtml='<!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title></head><body>cf-chl</body></html>';
