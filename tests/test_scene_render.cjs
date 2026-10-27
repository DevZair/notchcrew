const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const OfficeWorld=require('../source/scene-core.js');

// Exercise the actual Canvas renderer without a browser or an animation timer.
function context(){
  return new Proxy({measureText:text=>({width:String(text).length*7}),createRadialGradient:()=>({addColorStop(){}}),createLinearGradient:()=>({addColorStop(){}})}, {
    get(target,key){return key in target?target[key]:()=>{};},set(target,key,value){target[key]=value;return true;}
  });
}
function canvas(){return {width:0,height:0,getContext:()=>context(),getBoundingClientRect:()=>({width:720,height:420})};}
function button(){return {style:{},attributes:{},listeners:{},addEventListener(name,handler){this.listeners[name]=handler;},setAttribute(name,value){this.attributes[name]=value;}};}
const nodes=[];
const hitLayer={style:{},replaceChildren(){nodes.length=0;},append(node){nodes.push(node);}};
const sandbox={OfficeWorld,document:{createElement:type=>type==='canvas'?canvas():button()},matchMedia:()=>({matches:false}),performance:{now:()=>0},ResizeObserver:class{observe(){} disconnect(){}},setTimeout:()=>1,clearTimeout(){},STATUS:{working:'Работает',waiting:'Ждёт',resting:'Отдыхает',unknown:'Нет сигнала'}};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(require.resolve('../source/scene.js'),'utf8')+'\nglobalThis.Scene=OfficeScene;',sandbox);
let selected=null;
const scene=new sandbox.Scene(canvas(),hitLayer,id=>{selected=id;});
const agents=Array.from({length:48},(_,i)=>({id:`agent-${i}`,label:`Специалист ${i}`,status:['working','waiting','resting','unknown'][i%4]}));
scene.update(agents,'agent-3');scene.resize();
assert.equal(nodes.length,48,'Every specialist remains keyboard accessible');
for(let i=0;i<48;i++){
  assert.match(nodes[i].attributes['aria-label'],/Специалист/);
  assert(Number.parseFloat(nodes[i].style.left)>0&&Number.parseFloat(nodes[i].style.left)<100);
  assert(Number.parseFloat(nodes[i].style.top)>0&&Number.parseFloat(nodes[i].style.top)<100);
  assert.equal(nodes[i].attributes['aria-pressed'],String(i===3));
}
nodes[17].listeners.click();assert.equal(selected,'agent-17','Canvas hit target selects the correct specialist');
const previous=nodes[0];scene.update(agents.map(a=>({...a,status:'resting'})),null);
assert.equal(nodes[0],previous,'Status changes retain keyboard focus targets');
scene.setMotion(false);scene.setVisible(false);scene.stop();
console.log('Office Canvas: renders all states, 48 accessible hit targets, selection and stable targets passed.');
