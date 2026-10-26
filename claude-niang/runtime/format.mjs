// Money formatting for the detector.
const symbols={USD:'$',EUR:'€',GBP:'£',JPY:'¥',CNY:'¥'};
export function formatMoney(minor,currency='USD') {
  if(typeof minor!=='number' || !Number.isFinite(minor))return '—';
  const code=typeof currency==='string'?currency.toUpperCase():'USD';
  const digits=code==='JPY'?0:2;
  const value=(minor/(digits?100:1)).toFixed(digits);
  return (symbols[code]??code+' ')+value;
}

