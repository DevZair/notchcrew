'use strict';
const $=id=>document.getElementById(id);
const STATUS={working:'Работает',waiting:'Ждёт вас',resting:'Отдыхает',unknown:'Нет свежего сигнала'};
let state=null,selected=null,lastReceived=0,requestSignature='',rosterSignature='',activeTab='office';
const DETAILS={
  "architect": "Продумывает устройство системы и помогает выбрать техническое решение.",
  "code-architect": "Превращает идею функции в понятный план изменений кода.",
  "planner": "Разбивает большие задачи на шаги и следит за порядком работ.",
  "gan-planner": "Собирает требования к продукту, сценарии и критерии качества.",
  "type-design-analyzer": "Проверяет, что типы данных защищают от ошибок и понятны команде.",
  "code-explorer": "Изучает существующий проект и находит нужные связи в коде.",
  "docs-lookup": "Ищет ответы в документации библиотек и API.",
  "chief-of-staff": "Помогает разбирать сообщения, встречи и задачи.",
  "build-error-resolver": "Находит причины ошибок сборки JavaScript и TypeScript.",
  "cpp-build-resolver": "Разбирается с ошибками компиляции и сборки C++.",
  "csharp-reviewer": "Проверяет качество и надёжность кода C# и .NET.",
  "dart-build-resolver": "Исправляет ошибки сборки Dart и Flutter.",
  "go-build-resolver": "Помогает собрать и проверить проекты на Go.",
  "java-build-resolver": "Устраняет ошибки сборки Java, Maven и Gradle.",
  "kotlin-build-resolver": "Разбирается с ошибками Kotlin и Gradle.",
  "rust-build-resolver": "Исправляет ошибки сборки и владения данными в Rust.",
  "code-reviewer": "Смотрит на изменения свежим взглядом и ищет проблемы до выпуска.",
  "typescript-reviewer": "Проверяет типы, асинхронный код и безопасность JavaScript и TypeScript.",
  "python-reviewer": "Проверяет понятность, безопасность и качество кода Python.",
  "cpp-reviewer": "Проверяет память, ресурсы и надёжность кода C++.",
  "go-reviewer": "Следит за качеством Go и корректностью параллельной работы.",
  "java-reviewer": "Проверяет Java и Spring: слои, данные и обработку ошибок.",
  "kotlin-reviewer": "Проверяет Kotlin, корутины и Android-приложения.",
  "rust-reviewer": "Проверяет владение данными, безопасность и стиль Rust.",
  "a11y-architect": "Помогает сделать интерфейсы доступными для разных пользователей.",
  "tdd-guide": "Продумывает полезные тесты и проверяет поведение функций.",
  "e2e-runner": "Проверяет целые пользовательские сценарии в приложении.",
  "pr-test-analyzer": "Ищет пробелы в проверках перед объединением изменений.",
  "gan-evaluator": "Проверяет готовый продукт по сценариям и критериям качества.",
  "silent-failure-hunter": "Ищет незаметные ошибки и случаи, когда сбой остаётся скрытым.",
  "comment-analyzer": "Проверяет, что комментарии к коду остаются точными и полезными.",
  "flutter-reviewer": "Проверяет Flutter: виджеты, состояние, доступность и плавность.",
  "database-reviewer": "Проверяет структуру данных, SQL и работу базы.",
  "security-reviewer": "Ищет уязвимости и помогает защитить данные.",
  "performance-optimizer": "Ищет причины медленной работы и лишних затрат ресурсов.",
  "healthcare-reviewer": "Проверяет безопасность медицинских сценариев и обработки данных.",
  "pytorch-build-resolver": "Помогает с ошибками моделей PyTorch, тензоров и обучения.",
  "seo-specialist": "Проверяет техническую готовность сайта к поисковым системам.",
  "harness-optimizer": "Улучшает рабочую среду агентов и надёжность их инструментов.",
  "loop-operator": "Следит за длинными циклами работы и замечает остановки.",
  "gan-generator": "Собирает функции продукта и улучшает их по результатам проверок.",
  "code-simplifier": "Делает код проще и понятнее, сохраняя его поведение.",
  "refactor-cleaner": "Убирает ненужный код и помогает навести порядок в проекте.",
  "doc-updater": "Обновляет инструкции, документацию и карту проекта.",
  "opensource-forker": "Готовит отдельную копию проекта для открытого исходного кода.",
  "opensource-packager": "Готовит README, лицензию и материалы открытого проекта.",
  "opensource-sanitizer": "Проверяет, что в открытый релиз не попали приватные данные.",
  "conversation-analyzer": "Разбирает рабочие диалоги и находит способы улучшить процесс."
};
const pendingActions=new Map();let actionSequence=0;
function el(tag,className,text){const n=document.createElement(tag);if(className)n.className=className;if(text!==undefined)n.textContent=text;return n;}
const scene=new OfficeScene($('scene'),$('hit-layer'),selectAgent);
const media=matchMedia('(prefers-reduced-motion: reduce)');$('motion').checked=!media.matches;
media.addEventListener('change',e=>{$('motion').checked=!e.matches;scene.setMotion(!e.matches);});
$('motion').addEventListener('change',()=>scene.setMotion($('motion').checked));
$('chatter').addEventListener('change',()=>{scene.chatter=$('chatter').checked;scene.render();});
window.setOfficePresentation=compact=>{document.body.classList.toggle('notch',compact);requestAnimationFrame(()=>scene.resize());};
let appVisible=true;
window.setOfficeVisible=visible=>{appVisible=visible;scene.setVisible(visible&&activeTab==='office');};
function switchTab(name){activeTab=name;document.querySelectorAll('.page').forEach(p=>p.classList.toggle('active',p.id===name));document.querySelectorAll('[data-tab]').forEach(b=>{if(b.dataset.tab===name)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});scene.setVisible(appVisible&&name==='office');if(name==='office')requestAnimationFrame(()=>scene.resize());$('profile').hidden=true;if(name==='team')roster();}
document.querySelectorAll('[data-tab]').forEach(b=>b.addEventListener('click',()=>switchTab(b.dataset.tab)));
function selectAgent(id){selected=id;if(activeTab!=='office')switchTab('office');scene.update(state?.agents??[],selected);const a=state?.agents.find(a=>a.id===id);if(!a)return;const p=$('profile');p.replaceChildren();p.hidden=false;const close=el('button','close','×');close.setAttribute('aria-label','Закрыть сведения об агенте');close.onclick=()=>{p.hidden=true;selected=null;scene.update(state.agents,null);};p.append(close,el('p','eyebrow',a.department.toUpperCase()),el('h2','',a.label),el('div','role-id',a.id),el('span',`status-pill ${a.status}`,STATUS[a.status]),el('p','',DETAILS[a.id]||`Специалист отдела «${a.department}».`),el('p','muted',a.latest?`${a.latest.source} · ${a.latest.project||'Общая сессия'}`:'Готов подключиться, когда появится задача.'));if(a.status==='waiting'){const b=el('button','action','Посмотреть запросы →');b.onclick=()=>switchTab('requests');p.append(b);}}
function roster(){if(!state)return;const q=$('search').value.trim().toLowerCase();const signature=q+JSON.stringify(state.agents.map(a=>[a.id,a.status]));if(signature===rosterSignature)return;rosterSignature=signature;$('roster').replaceChildren();state.agents.filter(a=>`${a.label} ${a.id} ${a.department}`.toLowerCase().includes(q)).forEach((a,i)=>{const b=el('button','roster-row'),avatar=el('span','avatar');avatar.setAttribute('aria-hidden','true');avatar.style.setProperty('--shirt',['#869b7c','#7c9b9a','#ac8b7a','#9a83a0'][i%4]);const t=el('span');t.append(el('strong','',a.label),el('small','',`${a.department} · ${STATUS[a.status]}`));b.append(avatar,t);b.onclick=()=>selectAgent(a.id);$('roster').append(b);});}
$('search').addEventListener('input',roster);
function nativeAction(action,data={}){return new Promise((resolve,reject)=>{const bridge=window.webkit?.messageHandlers?.officeBridge;if(!bridge){reject(new Error('Этот ответ можно отправить из установленного приложения.'));return;}const token=`a${Date.now()}_${++actionSequence}`,timer=setTimeout(()=>{pendingActions.delete(token);reject(new Error('Нет подтверждения от приложения. Проверьте исходный чат.'));},8000);pendingActions.set(token,{resolve,reject,timer});bridge.postMessage({action,token,...data});});}
window.officeActionResult=result=>{const p=pendingActions.get(result.token);if(!p)return;clearTimeout(p.timer);pendingActions.delete(result.token);if(result.ok)p.resolve(result);else p.reject(new Error(result.error||'Не удалось передать ответ.'));};
function actionButton(card,label,kind,callback){const b=el('button',`action ${kind}`,label);b.type='button';b.onclick=async()=>{card.querySelectorAll('button').forEach(n=>n.disabled=true);const m=card.querySelector('.action-message');m.textContent='Передаём…';try{const result=await callback();m.textContent=result.message||'Передано в исходное приложение.';}catch(error){m.textContent=error.message;card.querySelectorAll('button').forEach(n=>n.disabled=false);}};return b;}
function requests(){const list=state.requests??[];const signature=JSON.stringify(list);if(signature===requestSignature)return;requestSignature=signature;const container=$('requests-list'),existing=new Map([...container.querySelectorAll('.request-card')].map(n=>[n.dataset.id,n]));container.querySelector('.empty')?.remove();const ids=new Set(list.map(r=>r.id));existing.forEach((n,id)=>{if(!ids.has(id))n.remove();});if(!list.length){const empty=el('div','empty');empty.append(el('div','empty-icon','☕'),el('h3','','Пока все справляются'),el('p','','Когда агент задаст вопрос или попросит разрешение, запрос появится здесь. А пока — можно спокойно пить кофе.'),el('p','muted','Codex и Claude Code: разрешения прямо здесь. Для Codex подключите и подтвердите хук офиса; старые сессии открываются в исходном чате.'));container.append(empty);return;}
list.forEach(r=>{if(existing.has(r.id)&&existing.get(r.id).dataset.fingerprint===(r.requestFingerprint||''))return;existing.get(r.id)?.remove();const c=el('article','request-card');c.dataset.id=r.id;c.dataset.fingerprint=r.requestFingerprint||'';c.append(el('p','eyebrow',r.kind==='question'?'ВОПРОС ОТ АГЕНТА':'НУЖЕН ВАШ ОТВЕТ'),el('h3','',r.label||'Агент'),el('div','metadata',`${r.source} · ${r.project||'Общая сессия'} · ${r.tool||'Ожидает решения'}`));const actions=el('div','request-actions'),message=el('p','action-message');message.setAttribute('role','status');
if(r.cwd)c.append(el('p','metadata',`Рабочая папка: ${r.cwd}`));
if(r.interactive&&r.source==='Codex')c.append(el('p','muted','Разовое разрешение Codex. Команда может выполняться за пределами песочницы. Проверьте всё действие; постоянные правила доступа не меняются.'));
if(r.interactive&&r.kind==='question'){
const fields=[];(r.questions??[]).forEach((q,i)=>{const f=el('fieldset'),legend=el('legend','',q.question);f.append(legend);const choices=[];(q.options??[]).forEach(option=>{const label=el('label','option'),input=el('input');input.type=q.multiSelect?'checkbox':'radio';input.name=`${r.id}_${i}`;input.value=option.label;const text=el('span');text.append(el('strong','',option.label),el('small','',option.description||''));label.append(input,text);f.append(label);choices.push(input);});const free=el('textarea','free-answer');free.rows=1;free.placeholder='Или свой ответ…';free.setAttribute('aria-label',`Свой ответ: ${q.question}`);f.append(free);fields.push({q,choices,free});c.append(f);});
actions.append(actionButton(c,'Отправить ответ','',()=>{const answers={};for(const f of fields){const chosen=f.choices.filter(n=>n.checked).map(n=>n.value);const text=f.free.value.trim();if(text)chosen.push(text);if(!chosen.length)throw new Error('Ответьте на каждый вопрос.');answers[f.q.question]=chosen.join(', ');}return nativeAction('reply',{id:r.id,fingerprint:r.requestFingerprint,behavior:'allow',answers});}));
}else if(r.interactive){c.append(el('p','muted','Агент просит выполнить это действие. Проверьте полный запрос перед решением.'),el('pre','',JSON.stringify(r.input??{},null,2)));actions.append(actionButton(c,'Разрешить один раз','',()=>nativeAction('reply',{id:r.id,fingerprint:r.requestFingerprint,behavior:'allow'})),actionButton(c,'Отклонить','danger',()=>nativeAction('reply',{id:r.id,fingerprint:r.requestFingerprint,behavior:'deny'})));}
else{c.append(el('p','muted','Ответьте в исходном чате — там доступны все детали запроса и кнопки подтверждения.'));if(r.command)c.append(el('pre','',r.command));}
if(r.interactive)actions.append(actionButton(c,r.source==='Codex'?'Ответить в Codex ↗':'Ответить в Claude Code','secondary',async()=>{const result=await nativeAction('reply',{id:r.id,fingerprint:r.requestFingerprint,behavior:'ask'});if(r.source==='Codex')return nativeAction('openSource',{source:'Codex',sessionId:r.sessionId});return result;}));
else actions.append(actionButton(c,r.source==='Codex'?'Открыть Codex ↗':'Скопировать ID сессии','secondary',()=>nativeAction(r.source==='Codex'?'openSource':'copySession',{source:r.source,sessionId:r.sessionId||''})));
c.append(actions,message);container.append(c);
});focusRequestedCard();}
function mainAgents(){const active=(state.general??[]).filter(s=>['working','waiting'].includes(s.status));const row=$('general-active');row.replaceChildren();row.hidden=!active.length;document.body.classList.toggle('has-general',active.length>0);for(const session of active){const card=el('article',`main-agent ${session.status}`),avatar=el('span','avatar');avatar.setAttribute('aria-hidden','true');const text=el('div');text.append(el('strong','',`${session.kind==='subagent'?'Подагент':'Главный агент'} · ${session.source}`),el('span','',session.project||'Общий чат'),el('small','',STATUS[session.status]));card.append(avatar,text);row.append(card);}}
window.receiveOffice=snapshot=>{if(!snapshot||!Array.isArray(snapshot.agents))return;state=snapshot;lastReceived=Date.now();$('notice').hidden=true;const counts={working:0,waiting:0,resting:0,unknown:0};state.agents.forEach(a=>counts[a.status]++);counts.working+=state.activity?.generalWorking??(state.general??[]).filter(s=>s.status==='working').length;counts.waiting+=state.activity?.generalWaiting??(state.general??[]).filter(s=>s.status==='waiting').length;mainAgents();for(const k of ['working','waiting','resting'])$(k).textContent=counts[k];$('unknown').textContent=counts.unknown?` · ${counts.unknown} нет сигнала`:'';$('team-count').textContent=state.agents.length;const n=(state.requests??[]).length;$('request-count').textContent=n;document.querySelector('[data-tab="requests"]').classList.toggle('attention',n>0);$('connection').classList.remove('offline');$('connection').querySelector('span').textContent='Онлайн';$('sync').textContent=`Обновлено ${new Date(snapshot.updatedAt*1000).toLocaleTimeString('ru-RU')}`;scene.update(state.agents,selected);if(activeTab==='team'||!$('roster').children.length)roster();requests();$('general-text').textContent=state.general?.length?state.general.map(s=>`${s.source} · ${s.project||'Общий чат'} · ${STATUS[s.status]}`).join(' / '):'Нет активных общих сессий.';$('sources').textContent=Object.entries(state.sources??{}).sort(([a],[b])=>a.localeCompare(b)).map(([name,ok])=>`${name}: ${ok?'события доступны':'нет свежих событий'}`).join(' · ');};
window.officeError=message=>{$('notice').textContent=message;$('notice').hidden=false;$('connection').classList.add('offline');$('connection').querySelector('span').textContent='Нет связи';if(state){$('general-active').replaceChildren();$('general-active').hidden=true;document.body.classList.remove('has-general');state.agents=state.agents.map(a=>({...a,status:'unknown'}));scene.update(state.agents,selected);$('working').textContent='0';$('waiting').textContent='0';$('resting').textContent='0';$('unknown').textContent='Нет свежего сигнала';}};
setInterval(()=>{if(lastReceived&&Date.now()-lastReceived>15000)window.officeError('События не обновляются. Переподключите сборщик через меню → Обновить события.');},5000);
switchTab('office');
let notificationState='notDetermined',requestedRequestID='';
window.setOfficeNotifications=status=>{
  notificationState=status;
  const messages={enabled:'Запросы появятся в уведомлениях и на экране блокировки. Для решения macOS потребует разблокировку.',denied:'Разрешите уведомления в Системных настройках → Уведомления → NotchCrew.',notDetermined:'Включите уведомления, чтобы отвечать с экрана блокировки Mac.',error:'Не удалось отправить уведомление. Ответ в чёлке остаётся доступен.',expired:'Этот запрос уже закрыт, изменился или истёк. Посмотрите текущие запросы ниже.'};
  $('notification-status').textContent=messages[status]||messages.notDetermined;
  $('notification-enable').textContent=status==='enabled'?'Проверить':'Включить';
};
$('notification-enable').addEventListener('click',()=>nativeAction(notificationState==='enabled'?'testNotification':'enableNotifications').catch(()=>window.setOfficeNotifications('error')));
function focusRequestedCard(){if(!requestedRequestID)return;const card=[...$('requests-list').children].find(n=>n.dataset.id===requestedRequestID);if(card){card.tabIndex=-1;card.scrollIntoView({block:'center'});card.focus({preventScroll:true});requestedRequestID='';}}
window.openOfficeRequests=id=>{requestedRequestID=typeof id==='string'?id:'';switchTab('requests');requestAnimationFrame(focusRequestedCard);};
