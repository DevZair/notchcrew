'use strict';
class OfficeScene {
  constructor(canvas, hitLayer, onSelect) {
    this.canvas=canvas; this.ctx=canvas.getContext('2d'); this.hitLayer=hitLayer; this.onSelect=onSelect;
    canvas.width=OfficeWorld.W;canvas.height=OfficeWorld.H;
    this.background=document.createElement('canvas');this.background.width=OfficeWorld.W;this.background.height=OfficeWorld.H;
    this.agents=[];this.buttons=[];this.selected=null;this.hovered=null;this.motion=!matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.chatter=true;this.visible=true;this.timer=null;this.start=performance.now();
    this.resizeObserver=new ResizeObserver(()=>this.resize());this.resizeObserver.observe(canvas);
    this.paintBackground();this.run();
  }
  rect(ctx,x,y,w,h,c) {ctx.fillStyle=c;ctx.fillRect(Math.round(x),Math.round(y),w,h);}
  plant(ctx,x,y,size=1) {
    ctx.save();ctx.translate(x,y);ctx.scale(size,size);
    const R=(...a)=>this.rect(ctx,...a);
    R(-12,-13,25,21,'#161922');R(-10,-12,21,3,'#41414c');R(-9,-7,18,12,'#242833');
    R(-2,-57,4,45,'#171c1b');
    [[-15,-59,17,18],[-3,-69,18,19],[-24,-45,24,18],[1,-47,22,17],[-8,-34,19,16]].forEach((r,i)=>R(...r,['#172624','#20312c','#142420','#1d2c26','#24382e'][i]));
    R(-11,-57,8,4,'#293b33');R(0,-66,8,3,'#344238');ctx.restore();
  }
  sofa(ctx,x,y,width=260) {
    const R=(...a)=>this.rect(ctx,...a);
    R(x-9,y+12,width+18,35,'#0a0b11');R(x-5,y,width+10,38,'#1b1a22');R(x,y-4,width,25,'#29262f');
    R(x+4,y,width-8,3,'#34303a');
    for(let a=x+9;a<x+width-10;a+=Math.max(42,Math.floor(width/3))){R(a,y+22,Math.min(72,width/3-5),18,'#25222b');R(a,y+22,Math.min(72,width/3-5),2,'#3b333d');}
    R(x-7,y+9,12,30,'#211f28');R(x+width-5,y+9,12,30,'#211f28');
    R(x+4,y+44,6,9,'#090b10');R(x+width-10,y+44,6,9,'#090b10');
  }
  table(ctx,x,y) {
    this.rect(ctx,x-3,y+4,6,28,'#0c0e12');this.rect(ctx,x-18,y+29,36,4,'#0b0d11');
    ctx.fillStyle='#262630';ctx.beginPath();ctx.ellipse(x,y+5,35,15,0,0,Math.PI*2);ctx.fill();
    ctx.fillStyle='#68616a';ctx.beginPath();ctx.ellipse(x,y,35,16,0,0,Math.PI*2);ctx.fill();
    this.rect(ctx,x-8,y-4,8,6,'#a79990');this.rect(ctx,x+7,y-3,7,5,'#37353f');
  }
  desk(ctx,index,active=false) {
    const p=OfficeWorld.home(index),x=p.x-39,y=p.y-62,R=(...a)=>this.rect(ctx,...a);
    R(x+3,y+28,84,36,'#080a102e');R(x+4,y+24,5,22,'#141015');R(x+75,y+24,5,22,'#141015');
    R(x,y,84,33,'#53413b');R(x,y,84,4,'#6c5547');R(x,y+29,84,5,'#332724');
    for(let n=0;n<4;n++)R(x+4,y+7+n*6,73,1,n%2?'#644b3e':'#46372f');
    R(x+25,y-30,43,34,'#767078');R(x+28,y-27,37,27,active?'#12252b':'#0b0c12');
    R(x+25,y-30,43,2,'#8d858b');R(x+43,y+4,6,7,'#81777a');R(x+35,y+10,22,3,'#8d8280');
    if(active){R(x+31,y-22,19,2,'#aec4b0');R(x+31,y-17,28,2,'#698e9e');R(x+31,y-12,12,2,'#cfb480');R(x+31,y-7,24,2,'#718b92');R(x+31,y-3,15,1,'#b0bca1');}
    R(x+27,y+18,31,7,'#8d8182');for(let k=0;k<7;k++)R(x+30+k*4,y+20,2,2,'#53464c');
    R(x+64,y+18,4,7,'#ada194');R(x+70,y+14,9,7,'#b3a99f');R(x+71,y+12,7,3,'#817570');R(x+77,y+15,3,4,'#8d817d');
    R(x+5,y+11,8,8,'#a0938c');R(x+11,y+11,3,3,'#c1b3a8');
    R(x+24,y+42,34,15,'#12131a');R(x+28,y+34,26,17,'#22212a');R(x+29,y+35,24,3,'#2f2b32');
    R(x+39,y+55,4,9,'#121218');R(x+26,y+64,31,3,'#111218');R(x+26,y+61,3,7,'#111218');R(x+54,y+61,3,7,'#111218');
  }
  lamp(ctx,x,y) {
    const R=(...a)=>this.rect(ctx,...a);R(x-2,y-65,4,65,'#111219');R(x-11,y-3,22,7,'#111219');
    R(x-12,y-89,24,23,'#ffd09a');R(x-16,y-82,32,17,'#ffe5b0');R(x-9,y-94,18,7,'#e4a46f');
    const g=ctx.createRadialGradient(x,y-74,1,x,y-74,120);g.addColorStop(0,'#ffd4a28a');g.addColorStop(.12,'#ffc88c35');g.addColorStop(1,'#ffc88c00');ctx.fillStyle=g;ctx.fillRect(x-120,y-194,240,240);
  }
  paintBackground() {
    const c=this.background.getContext('2d'),R=(...a)=>this.rect(c,...a);
    R(0,0,1440,840,'#080a12');R(20,13,1400,811,'#171923');R(26,20,1388,794,'#242634');
    c.save();c.beginPath();c.rect(26,20,1388,794);c.clip();
    // Large, quiet concrete tiles and deterministic flecks, like a dim late-night studio.
    for(let row=0,y=119;y<814;y+=90,row++)for(let col=0,x=26;x<1414;x+=108,col++){
      const tone=['#343544','#323443','#363643','#303342'][(row*3+col)%4];R(x,y,107,89,tone);R(x,y,107,2,'#282b3740');
      for(let n=0;n<18;n++){const dx=(col*31+row*17+n*41)%104,dy=(row*23+col*11+n*29)%86;R(x+dx,y+dy,2,n%3===0?2:1,n%2?'#14172520':'#67637212');}
    }
    R(26,20,1388,112,'#12141f');R(26,128,1388,7,'#242632');R(26,135,1388,3,'#3a394540');
    for(const x of [97,815]){
      R(x-6,26,221,93,'#080a12');R(x,31,209,77,'#0c1021');R(x,57,209,1,'#181a31');
      R(x+99,31,5,77,'#080a12');R(x,54,209,5,'#070a11');R(x-9,109,228,8,'#3e3b50');R(x-6,108,222,3,'#555163');
      const g=c.createLinearGradient(x,30,x,108);g.addColorStop(0,'#11101f00');g.addColorStop(1,'#191e423c');c.fillStyle=g;c.fillRect(x,31,209,77);
    }
    // Tall bookshelf, station display, clock and coffee shelf on the upper wall.
    R(347,29,152,101,'#141112');R(353,34,139,91,'#1f1b20');
    for(let row=0;row<3;row++){for(let i=0;i<12;i++)R(356+i*11,39+row*28+(i%3),6+(i%3),23-(i%4),['#42404c','#5a4c50','#343a46','#67616a','#2b3542'][i%5]);R(348,62+row*29,151,6,'#392e2e');}
    R(527,24,182,80,'#11171c');R(531,28,174,71,'#20282d');R(534,31,167,2,'#3d474b');R(646,31,3,65,'#42484b');R(535,62,107,3,'#3b4148');
    for(let i=0;i<7;i++){R(537+i*5,48-i*3,3,4,i<3?'#8ac2ab':'#c3c6d0');R(537+i*14,88,3,3,i%3?'#aebec8':'#83c3ad');}
    R(654,39,13,13,'#838e9f');R(657,42,7,7,'#20282d');R(654,62,44,3,'#464d56');
    c.fillStyle='#a6b2bd';c.font='bold 16px monospace';c.fillText('48',656,88);
    R(748,49,27,28,'#363747');R(753,45,17,35,'#363747');R(745,54,33,18,'#363747');R(760,51,3,14,'#151720');R(761,62,8,3,'#151720');
    R(1116,73,265,6,'#1f202a');R(1119,43,47,31,'#383746');R(1122,39,41,7,'#4b4b5d');R(1132,52,18,6,'#171925');R(1147,57,5,7,'#171925');
    [[1191,62,9,11],[1207,62,9,11],[1231,56,12,17]].forEach((r,i)=>R(...r,['#424357','#474153','#243632'][i]));
    this.plant(c,66,135,.9);this.plant(c,1069,156,.75);
    // Forty-eight desks retain individual agents and keyboard hit targets.
    for(let i=0;i<48;i++)this.desk(c,i);
    // A low-lit lounge and café, separated by furniture rather than a bright divider.
    R(1111,375,287,349,'#14211f');R(1112,376,285,348,'#162523');
    for(let y=379;y<719;y+=8)for(let x=1115;x<1396;x+=11)if((x+y)%3===0)R(x,y,2,2,'#0d171b35');
    this.sofa(c,1150,406,203);this.sofa(c,1150,477,203);this.sofa(c,1150,546,203);this.sofa(c,1150,613,203);
    this.table(c,1251,692);
    R(1128,175,255,37,'#453831');R(1128,173,255,5,'#645146');R(1135,210,5,18,'#171317');R(1370,210,5,18,'#171317');
    R(1140,143,47,33,'#35343f');R(1144,147,36,14,'#696b74');R(1148,150,27,7,'#121722');R(1159,162,12,9,'#16171d');R(1156,172,15,6,'#c4b8a3');
    R(1224,168,10,8,'#b2aaa1');R(1241,168,10,8,'#c9c0b5');R(1338,159,15,15,'#35493b');
    this.table(c,1208,283);this.table(c,1344,283);
    this.plant(c,1101,386,.83);this.plant(c,1381,768,.95);this.plant(c,1030,782,.8);
    // Server racks and a filing cabinet anchor the near edge of the room.
    for(let rack=0;rack<2;rack++){const x=44+rack*69;R(x,710,62,91,'#090c12');R(x+4,714,54,80,'#12131c');for(let y=718;y<789;y+=10){R(x+7,y,48,6,'#080c13');R(x+11,y+2,3,2,'#83c8ac');R(x+18,y+2,2,2,'#425c52');for(let n=0;n<6;n++)R(x+27+n*4,y+2,2,2,'#19232b');}R(x+3,799,6,7,'#080a0f');R(x+53,799,6,7,'#080a0f');}
    R(251,729,52,64,'#41404e');for(let y=733;y<792;y+=20){R(254,y,46,17,'#4b4857');R(266,y+6,17,2,'#292a36');}
    // Soft pools of practical light; no single flat wash over the pixel furniture.
    for(const [x,y,r,a] of [[254,394,310,.19],[708,346,330,.14],[509,633,280,.13]]){const g=c.createRadialGradient(x,y,20,x,y,r);g.addColorStop(0,`rgba(239,192,162,${a})`);g.addColorStop(1,'rgba(239,192,162,0)');c.fillStyle=g;c.fillRect(x-r,y-r,r*2,r*2);}
    this.lamp(c,1380,457);this.lamp(c,1080,708);
    const vignette=c.createRadialGradient(724,415,200,724,415,810);vignette.addColorStop(0,'#03050d00');vignette.addColorStop(.7,'#03050d0c');vignette.addColorStop(1,'#03050d99');c.fillStyle=vignette;c.fillRect(26,20,1388,794);
    c.restore();R(20,813,1400,11,'#12151e');R(20,13,5,811,'#1f2330');R(1415,13,5,811,'#11141e');
  }
  update(agents,selected) {
    if(this.agents.map(a=>a.id).join('|')!==agents.map(a=>a.id).join('|')){
      this.hitLayer.replaceChildren();this.buttons=agents.map(agent=>{
        const button=document.createElement('button');button.className='agent-hit';button.type='button';
        button.addEventListener('click',()=>this.onSelect(agent.id));
        button.addEventListener('mouseenter',()=>{this.hovered=agent.id;this.render();});
        button.addEventListener('mouseleave',()=>{this.hovered=null;});
        this.hitLayer.append(button);return button;
      });
    }
    this.agents=agents;this.selected=selected;
    this.buttons.forEach((button,i)=>{button.setAttribute('aria-label',`${agents[i].label}. ${STATUS[agents[i].status]}`);button.title=`${agents[i].label} · ${STATUS[agents[i].status]}`;});
    this.render();
  }
  resize() {
    const r=this.canvas.getBoundingClientRect(),scale=Math.min(r.width/OfficeWorld.W,r.height/OfficeWorld.H);
    Object.assign(this.hitLayer.style,{left:`${(r.width-OfficeWorld.W*scale)/2}px`,top:`${(r.height-OfficeWorld.H*scale)/2}px`,width:`${OfficeWorld.W*scale}px`,height:`${OfficeWorld.H*scale}px`});
  }
  person(c,p,index) {
    const R=(...a)=>this.rect(c,...a),hair=['#493e34','#74533d','#b99c67','#8d8776'][index%4],skin=['#d4ae89','#bc8d70','#e1c3a1','#a57659'][index%4],shirt=['#536f87','#8a697f','#8a946b','#71968c','#b08b70','#7887a2'][index%6];
    const t=(performance.now()-this.start)/1000,bob=p.walking&&this.motion?(Math.floor(t*6)%2):0;
    c.save();c.translate(Math.round(p.x),Math.round(p.y)-bob);
    c.fillStyle='#05070c55';c.beginPath();c.ellipse(0,2,15,5,0,0,Math.PI*2);c.fill();
    const step=p.walking&&this.motion?(Math.floor(t*7)%2?3:-3):0;
    R(-7,-9,5,10+step,'#292b3a');R(2,-9,5,10-step,'#242735');R(-9,0+step,8,3,'#a7a2b0');R(2,0-step,8,3,'#a7a2b0');
    R(-9,-26,18,20,shirt);R(-12,-24,4,15,skin);R(9,-24,4,15,skin);
    R(-8,-41,16,17,skin);R(-10,-43,20,8,hair);R(-10,-38,5,9,hair);R(4,-34,2,2,'#3d3d37');
    if(['idle','coffee','sofa'].includes(p.mode)){R(11,-17,7,8,'#c9bdad');R(17,-15,3,4,'#d4c7a5');if(this.motion&&Math.floor(t)%3===0)R(13,-24,1,4,'#c9c6c0');}
    if(p.mode==='working'){R(-13,-22,7,4,skin);R(7,-22,7,4,skin);}
    if(p.mode==='waiting'){R(13,-51,16,17,'#e9bb67');c.fillStyle='#5c4730';c.font='bold 14px monospace';c.fillText('!',17,-38);}
    if(p.mode==='unknown'){R(13,-51,16,17,'#b5b1bc');c.fillStyle='#4b4653';c.font='bold 14px monospace';c.fillText('?',17,-38);}
    c.restore();
  }
  bubble(c,p,text) {
    c.font='14px monospace';const words=text.split(' '),lines=[''];
    words.forEach(word=>{const n=lines.length-1;if(c.measureText(lines[n]+word).width>215)lines.push(word+' ');else lines[n]+=word+' ';});
    const width=Math.min(240,Math.max(...lines.map(l=>c.measureText(l).width))+22),height=lines.length*19+15;
    const x=Math.max(28,Math.min(1410-width,p.x-width/2)),y=Math.max(90,p.y-62-height);
    c.fillStyle='#00000055';c.beginPath();c.roundRect(x+3,y+4,width,height,7);c.fill();
    c.fillStyle='#181a24f2';c.beginPath();c.roundRect(x,y,width,height,7);c.fill();
    c.beginPath();c.moveTo(p.x-5,y+height-1);c.lineTo(p.x+6,y+height-1);c.lineTo(p.x,y+height+8);c.closePath();c.fill();
    c.fillStyle='#d2cfd7';lines.forEach((line,i)=>c.fillText(line.trim(),x+11,y+20+i*19));
  }
  render() {
    const c=this.ctx;c.clearRect(0,0,OfficeWorld.W,OfficeWorld.H);c.drawImage(this.background,0,0);
    const seconds=(performance.now()-this.start)/1000;
    const people=this.agents.map((agent,i)=>({agent,index:i,p:OfficeWorld.pose(i,agent.status,seconds,this.motion)}));
    people.forEach(({agent,index})=>{if(agent.status==='working')this.desk(c,index,true);});
    people.sort((a,b)=>a.p.y-b.p.y).forEach(({agent,index,p})=>{
      if(agent.id===this.selected||agent.id===this.hovered){c.strokeStyle='#b4bfdc';c.lineWidth=2;c.beginPath();c.ellipse(p.x,p.y+3,19,7,0,0,Math.PI*2);c.stroke();}
      this.person(c,p,index);
      if(agent.id===this.hovered||agent.id===this.selected||['working','waiting'].includes(agent.status)){
      const label=agent.label.length>16?agent.label.slice(0,15)+'…':agent.label;
      c.font='12px monospace';const width=c.measureText(label).width+10;
      const labelX=Math.max(28+width/2,Math.min(1412-width/2,p.x));
      c.fillStyle='#11131fe8';c.fillRect(labelX-width/2,p.y+8,width,17);c.fillStyle=agent.status==='waiting'?'#ffe1a0':'#d5d4df';c.textAlign='center';c.fillText(label,labelX,p.y+21);c.textAlign='left';
      }
      const button=this.buttons[index];button.style.left=`${p.x/OfficeWorld.W*100}%`;button.style.top=`${(p.y+5)/OfficeWorld.H*100}%`;
      button.setAttribute('aria-pressed',String(agent.id===this.selected));
    });
    const waiting=people.filter(p=>p.agent.status==='waiting').slice(0,2);
    waiting.forEach(({p})=>this.bubble(c,p,'Босс, нужен ваш ответ. Я тут.'));
    if(this.chatter&&waiting.length<2&&this.agents.length){
      const round=Math.floor(seconds/7),candidates=people.filter(p=>p.agent.status==='resting');
      for(let b=0;b<2-waiting.length&&candidates.length;b++){
        const person=candidates[(round*7+b*19)%candidates.length];
        this.bubble(c,person.p,OfficeWorld.CHATTER[(round*3+b*7)%OfficeWorld.CHATTER.length]);
      }
    }
  }
  run() {
    if(this.timer!==null)clearTimeout(this.timer);this.timer=null;
    if(!this.visible)return;this.render();
    if(this.motion)this.timer=setTimeout(()=>this.run(),1000/15);
  }
  setVisible(visible){this.visible=visible;this.run();}
  setMotion(motion){this.motion=motion;this.run();}
  stop(){if(this.timer!==null)clearTimeout(this.timer);this.resizeObserver.disconnect();}
}
