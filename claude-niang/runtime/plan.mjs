// Claude plan identification. A plan name is metadata only: the windows shown
// in the bubble always come from what claude.ai actually returns.
const names={free:'Free',pro:'Pro',max:'Max',max_5x:'Max 5x',max_20x:'Max 20x',team:'Team',enterprise:'Enterprise'};

export function normalizePlan(value) {
  if(typeof value!=='string')return null;
  const plan=value.trim().toLowerCase();
  return plan && plan.length<=80 && !/[\x00-\x1f\x7f]/.test(plan)?plan:null;
}

function textList(value) {
  return Array.isArray(value)?value.filter(item=>typeof item==='string').map(item=>item.trim().toLowerCase()):[];
}

// Organization objects come from claude.ai /api/organizations (or the bootstrap
// membership record). Known signals: capabilities (claude_pro / claude_max),
// rate_limit_tier (default_claude_max_5x / _20x) and raven_type (Team/Enterprise).
export function identifyClaudePlan(org) {
  if(!org || typeof org!=='object' || Array.isArray(org))return {plan:null,planLabel:'未知套餐',planKnown:false,planSource:null,rateLimitTier:null};
  const capabilities=textList(org.capabilities);
  const tier=typeof org.rate_limit_tier==='string'?org.rate_limit_tier.trim().toLowerCase():'';
  const raven=typeof org.raven_type==='string'?org.raven_type.trim().toLowerCase():(org.raven_type?'team':'');
  const billing=typeof org.billing_type==='string'?org.billing_type.trim().toLowerCase():'';
  let plan=null;
  if(raven || capabilities.includes('raven')){
    plan=(raven.includes('enterprise') || capabilities.includes('enterprise') || billing.includes('enterprise'))?'enterprise':'team';
  }else if(capabilities.includes('claude_max') || /(^|_)max(_|$)/.test(tier) || tier.includes('claude_max')){
    plan=tier.includes('20x')?'max_20x':tier.includes('5x')?'max_5x':'max';
  }else if(capabilities.includes('claude_pro')){
    plan='pro';
  }else if(capabilities.includes('chat')){
    plan='free';
  }else{
    // Keep a future subscription capability usable without inventing limits.
    const future=capabilities.find(item=>/^claude_[a-z0-9_]+$/.test(item));
    plan=future?normalizePlan(future.replace(/^claude_/,'')):null;
  }
  const label=plan?(names[plan]??prettify(plan)):'未知套餐';
  return {plan,planLabel:label,planKnown:plan!==null && Object.hasOwn(names,plan),planSource:plan?'organization':null,rateLimitTier:tier||null};
}

function prettify(plan) {
  return plan.split(/[_\s-]+/).filter(Boolean).map(part=>part.length<=3 && /\d/.test(part)?part:part.charAt(0).toUpperCase()+part.slice(1)).join(' ');
}

// Model display names for per-model weekly windows.
const models={opus:'Opus',sonnet:'Sonnet',haiku:'Haiku',fable:'Fable',mythos:'Mythos'};
export function modelLabel(value) {
  if(typeof value!=='string')return null;
  const key=value.trim().toLowerCase();
  if(!key || key.length>40 || /[\x00-\x1f\x7f]/.test(key))return null;
  for(const [needle,label] of Object.entries(models)){if(key.includes(needle))return label;}
  return value.trim().charAt(0).toUpperCase()+value.trim().slice(1);
}

export function quotaWindowLabel(window) {
  if(!window)return '额度';
  if(window.kind==='session')return '5 小时';
  if(window.kind==='weekly')return '每周';
  if(window.kind==='weekly-model')return window.model?'每周 · '+window.model:'每周 · 模型';
  if(window.kind==='extra')return '额外用量';
  if(window.kind==='credits')return '预付余额';
  const minutes=Number(window.minutes);
  if(minutes===300)return '5 小时';
  if(minutes===10080)return '每周';
  if(Number.isSafeInteger(minutes) && minutes>0){
    if(minutes%1440===0)return (minutes/1440)+' 天';
    if(minutes%60===0)return (minutes/60)+' 小时';
    return minutes+' 分钟';
  }
  return '额度';
}
