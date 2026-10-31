package io.github.haige120.cloudreader.core.reader

/** Script used only after preparing script-free local HTML. The bridge belongs to the host. */
object ReflowScript {
    val script = """
(function(){
 let mode='PAGE',gap=32,stride=innerWidth+32, columns=1, configured=false, lastConfig,pendingRestore=null,configEpoch=0,restoreEpoch=0;
 const scrollElement=()=>document.scrollingElement||document.documentElement;
 const extent=()=>Math.max(0,mode==='SCROLL'?scrollElement().scrollHeight-innerHeight:scrollElement().scrollWidth-innerWidth);
 const progress=()=>extent()===0?0:(mode==='SCROLL'?scrollY:scrollX)/extent();
 const textAnchor=()=>{let offset=0;const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;while(node=walker.nextNode()){const range=document.createRange();range.selectNodeContents(node);const rects=Array.from(range.getClientRects());if(rects.some(r=>r.right>0&&r.left<innerWidth&&r.bottom>0&&r.top<innerHeight)){let lo=0,hi=node.length;while(lo<hi){const mid=(lo+hi)>>1;range.setStart(node,mid);range.setEnd(node,Math.min(node.length,mid+1));const r=range.getBoundingClientRect();if(mode==='SCROLL'?r.bottom<=0:r.right<=0)lo=mid+1;else hi=mid;}return offset+lo;}offset+=node.length;}return 0;};
 const restoreAnchor=offset=>{const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;while(node=walker.nextNode()){if(offset<node.length){const range=document.createRange();range.setStart(node,offset);range.setEnd(node,Math.min(node.length,offset+1));const rect=range.getBoundingClientRect();if(mode==='SCROLL')scrollTo(0,scrollY+rect.top);else scrollTo(Math.floor((scrollX+rect.left)/stride)*stride,0);report();return;}offset-=node.length;}report();};
 let timer;
 const report=()=>{clearTimeout(timer);timer=setTimeout(()=>{if(pendingRestore||innerWidth<=0||innerHeight<=0)return;const pages=mode==='SCROLL'?Math.max(1,Math.ceil(scrollElement().scrollHeight/innerHeight)):Math.max(1,Math.ceil((scrollElement().scrollWidth+gap)/stride));const physical=mode==='SCROLL'?Math.floor(scrollY/innerHeight)+1:Math.round(scrollX/stride)*columns+1;nativeReader.location(Math.max(0,Math.min(1,progress())),physical,mode==='SCROLL'?pages:pages*columns,textAnchor());},150);};
 const applyPending=()=>{if(!pendingRestore||!configured||innerWidth<=0||innerHeight<=0)return;document.body.getBoundingClientRect();const target=pendingRestore;pendingRestore=null;if(target.anchor!==undefined)restoreAnchor(target.anchor);else{if(mode==='SCROLL')scrollTo(0,target.fraction*extent());else scrollTo(Math.min(extent(),Math.round(target.fraction*extent()/stride)*stride),0);report();}};
 window.reader={
 restoreSource(offset){restoreEpoch++;pendingRestore={anchor:Math.max(0,offset)};requestAnimationFrame(applyPending);},
 configure(size,font,bg,fg,layout){const epoch=++configEpoch,restoration=restoreEpoch,target=pendingRestore;const hadConfig=configured;const anchor=hadConfig?textAnchor():0;configured=true;lastConfig=[size,font,bg,fg,layout];mode=layout;columns=layout==='SPREAD'&&innerWidth>=700?2:1;stride=innerWidth+gap;
 let style=document.getElementById('reader-style');if(!style){style=document.createElement('style');style.id='reader-style';document.head.appendChild(style);}
 style.textContent='html,body{margin:0;background:'+bg+';color:'+fg+';font:'+size+'px/1.65 '+font+';}body *{max-width:100%;box-sizing:border-box;}img{max-width:100%;max-height:90vh;object-fit:contain;}p,h1,h2,h3,section,article{padding-inline:24px;}a{color:inherit;}'+(layout==='SCROLL'?'body{padding:24px;max-width:900px;margin:auto;}':'html{overflow-x:hidden;overflow-y:hidden;}body{width:100vw;height:100vh;column-width:'+((innerWidth-gap*(columns-1))/columns)+'px;column-gap:'+gap+'px;column-fill:auto;}');
 requestAnimationFrame(()=>{if(epoch!==configEpoch)return;if(pendingRestore)applyPending();else if(restoration!==restoreEpoch)return;else if(target){pendingRestore=target;applyPending();}else if(hadConfig)restoreAnchor(anchor);else report();});},
 restore(fraction){restoreEpoch++;pendingRestore={fraction:Math.max(0,Math.min(1,fraction))};requestAnimationFrame(applyPending);},
 turn(direction){const current=mode==='SCROLL'?scrollY:scrollX;const amount=mode==='SCROLL'?innerHeight*.85:stride;const target=Math.max(0,Math.min(extent(),current+direction*amount));if(Math.abs(target-current)<2){nativeReader.boundary(direction);return;}if(mode==='SCROLL')scrollTo(0,target);else scrollTo(target,0);report();}
 };
 addEventListener('scroll',report,{passive:true});
 addEventListener('resize',()=>{if(lastConfig)reader.configure(...lastConfig);});
 let wheel=0;addEventListener('wheel',event=>{if(mode==='SCROLL')return;event.preventDefault();wheel+=Math.abs(event.deltaX)>Math.abs(event.deltaY)?event.deltaX:event.deltaY;clearTimeout(window.turnTimer);window.turnTimer=setTimeout(()=>{if(Math.abs(wheel)>5)reader.turn(wheel>0?1:-1);wheel=0;},100);},{passive:false});
 addEventListener('keydown',event=>{if(event.key==='ArrowRight'||event.key==='PageDown'){event.preventDefault();reader.turn(1);}if(event.key==='ArrowLeft'||event.key==='PageUp'){event.preventDefault();reader.turn(-1);}});
 let touch;document.addEventListener('touchstart',e=>{if(e.touches.length===1)touch={x:e.touches[0].clientX,y:e.touches[0].clientY};},{passive:true});document.addEventListener('touchend',e=>{if(!touch||!e.changedTouches.length)return;const dx=e.changedTouches[0].clientX-touch.x,dy=e.changedTouches[0].clientY-touch.y;touch=null;if(mode!=='SCROLL'&&Math.abs(dx)>60&&Math.abs(dx)>Math.abs(dy)*1.5&&!String(getSelection()).trim())reader.turn(dx<0?1:-1);},{passive:true});
 document.addEventListener('click',event=>{if(!getSelection().toString()&&!event.target.closest('a'))nativeReader.tap();});
 report();
})();
""".trimIndent()
}
