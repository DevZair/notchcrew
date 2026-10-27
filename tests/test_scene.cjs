const assert=require('node:assert/strict');
const world=require('../source/scene-core.js');
let walking=0,coffee=0,sofa=0;
for(let i=0;i<48;i++){
  for(let t=0;t<480;t+=.5){
    const p=world.pose(i,'resting',t);
    assert(p.x>25&&p.x<world.W-25&&p.y>80&&p.y<world.H-30,'Person stays inside the office');
    walking+=p.walking?1:0;coffee+=p.mode==='coffee'?1:0;sofa+=p.mode==='sofa'?1:0;
    for(const status of ['working','waiting','unknown']) assert(!world.pose(i,status,t).walking,'Only resting agents wander');
  }
  for(const t of [129.999,149.999,184.999,194.999,219.999,239.999]){
    const clock=t-i*5+240;
    const a=world.pose(i,'resting',clock),b=world.pose(i,'resting',clock+.002);
    assert(Math.hypot(a.x-b.x,a.y-b.y)<2,'Walks have no teleport at phase boundaries');
  }
  assert.deepEqual(world.pose(i,'resting',0,false),world.pose(i,'resting',900,false),'Reduced motion freezes positions');
  assert.deepEqual(world.pose(i,'working',0),world.pose(i,'working',900),'Work remains at a real desk');
}
assert(walking>0&&coffee>0&&sofa>0);
assert.equal(new Set(Array.from({length:48},(_,i)=>JSON.stringify(world.home(i)))).size,48);
console.log('Office scene: all 48 places, continuous routes, bounds, rest/work states and reduced motion passed.');
