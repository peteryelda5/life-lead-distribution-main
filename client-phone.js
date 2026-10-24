/* Shared CRM and deal-entry phone formatting. */
window.PortalClientPhone=(()=>{
 function displayPhone(value){
  const text=String(value??''),trimmed=text.trim();
  // Keep extensions and international numbers intact; never truncate contact data.
  if(!/^\+?[\d\s().-]*$/.test(trimmed)||trimmed.startsWith('+')&&!trimmed.startsWith('+1'))return text;
  let digits=trimmed.replace(/\D/g,''),prefix='';
  if(trimmed.startsWith('+1')){prefix='+1';digits=digits.slice(1);}
  else if(digits.length===11&&digits[0]==='1'){prefix='1';digits=digits.slice(1);}
  if(digits.length>10)return text;
  const local=[digits.slice(0,3),digits.slice(3,6),digits.slice(6,10)].filter(Boolean).join('-');
  return prefix+(prefix&&local?'-':'')+local;
 }
 function bindPhoneInputs(form){
  form.querySelectorAll('input[type="tel"]').forEach(field=>{
   field.value=displayPhone(field.value);field.placeholder='123-123-1234';
   const format=()=>{
    const raw=field.value,next=displayPhone(raw);if(raw===next)return;
    const start=field.selectionStart??raw.length,end=field.selectionEnd??start;
    const position=offset=>{if(offset===0)return 0;if(offset===raw.length)return next.length;const count=raw.slice(0,offset).replace(/\D/g,'').length;if(!count)return next.startsWith('+')?1:0;let found=0;for(let i=0;i<next.length;i++)if(/\d/.test(next[i])&&++found===count)return i+1;return next.length;};
    const range=[position(start),position(end)];field.value=next;field.setSelectionRange(...range);
   };
   field.addEventListener('input',event=>{if(!event.isComposing)format();});field.addEventListener('compositionend',format);field.addEventListener('blur',format);
   field.addEventListener('beforeinput',event=>{
    const start=field.selectionStart,end=field.selectionEnd;if(start!==end||start==null)return;
    let from=start,to=end;
    if(event.inputType==='deleteContentBackward'&&field.value[start-1]==='-'){from=Math.max(0,start-2);}
    else if(event.inputType==='deleteContentForward'&&field.value[start]==='-'){to=Math.min(field.value.length,start+2);}
    else return;
    event.preventDefault();field.setRangeText('',from,to,'start');field.dispatchEvent(new Event('input',{bubbles:true}));
   });
  });
 }
 return {display:displayPhone,bind:bindPhoneInputs};
})();
