(function (root) {
  'use strict';
  const W = 1440, H = 840;
  const CHATTER = [
    'Задач пока нет. Кофе есть.', 'Кажется, босс опять в Instagram.',
    'Босс, мы готовы. Почти как дедлайн.', 'Пойду обновлю кофе, а не зависимости.',
    'Тесты зелёные. Чай тоже.', 'Планёрка перенесена. На диван.',
    'Кофе с нулевой сложностью. O(1).', 'Я не бездельничаю. Я кеширую силы.',
    'Кажется, «ещё один рилс» затянулся.', 'Пока нет ТЗ, у нас тихий час.',
    'У кого-нибудь есть задача? Или печенье?', 'Отдых — тоже часть архитектуры.',
    'Предлагаю назвать этот спринт «капучино».', 'Багов нет. Мы ничего не трогали.',
    'Задача придёт — я уже тут.', 'Сначала кофе. Потом сложность.',
    'Босс, моргни, если нужен рефакторинг.', 'Сегодня дежурю у кофемашины.',
    'Мой следующий коммит — на диван.', 'Всё под контролем. Кроме печенья.',
  ];
  function home(index) { return {x: 91 + (index % 8) * 121, y: 236 + Math.floor(index / 8) * 84}; }
  function coffee(index) {
    const slots = [[1152,218],[1202,218],[1252,218],[1302,218],
      [1155,272],[1208,252],[1261,272],[1208,317],
      [1291,272],[1344,252],[1394,272],[1344,317],
      [1148,352],[1214,352],[1280,352],[1346,352]];
    return {x:slots[index % 16][0], y:slots[index % 16][1]};
  }
  function sofa(index) { return {x:1150 + (index % 4) * 65, y:455 + Math.floor((index % 16) / 4) * 68}; }
  function route(from, to, index) {
    const aisle = home(index).y + 12;
    const approach = to.y >= 310 ? 365 : 200;
    return [from, {x:from.x,y:aisle}, {x:1043,y:aisle}, {x:1043,y:705}, {x:1114,y:705}, {x:1114,y:approach}, {x:to.x,y:approach}, to];
  }
  function onPath(path, progress) {
    const lengths = path.slice(1).map((p,i)=>Math.hypot(p.x-path[i].x,p.y-path[i].y));
    let distance = Math.max(0,Math.min(1,progress)) * lengths.reduce((a,b)=>a+b,0);
    for (let i=0;i<lengths.length;i++) {
      if (distance <= lengths[i] && lengths[i] > 0) {
        const t=distance/lengths[i], a=path[i], b=path[i+1];
        return {x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t, direction:Math.abs(b.x-a.x)>Math.abs(b.y-a.y)?Math.sign(b.x-a.x):0};
      }
      distance -= lengths[i];
    }
    return {...path[path.length-1],direction:0};
  }
  function pose(index, status, seconds, motion = true) {
    const h=home(index);
    if (status === 'working') return {...h,mode:'working',walking:false};
    if (status === 'waiting') return {...h,y:h.y+10,mode:'waiting',walking:false};
    if (status !== 'resting') return {...h,mode:'unknown',walking:false};
    const phase=((motion?seconds:0)+index*5)%240;
    const c=coffee(index), s=sofa(index);
    if (phase<130) return {...h,mode:'idle',walking:false};
    if (phase<150) return {...onPath(route(h,c,index),(phase-130)/20),mode:'walking',walking:motion};
    if (phase<185) return {...c,mode:'coffee',walking:false};
    const approach=c.y>=310?365:200;
    if (phase<195) return {...onPath([c,{x:c.x,y:approach},{x:1114,y:approach},{x:1114,y:s.y},s],(phase-185)/10),mode:'walking',walking:motion};
    if (phase<220) return {...s,mode:'sofa',walking:false};
    const back=[s,{x:1114,y:s.y},{x:1114,y:705},{x:1043,y:705},{x:1043,y:h.y+12},{x:h.x,y:h.y+12},h];
    return {...onPath(back,(phase-220)/20),mode:'walking',walking:motion};
  }
  const api={W,H,CHATTER,home,coffee,sofa,route,onPath,pose};
  if (typeof module !== 'undefined' && module.exports) module.exports=api;
  else root.OfficeWorld=api;
})(typeof window !== 'undefined' ? window : globalThis);
