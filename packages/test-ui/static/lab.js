const $ = (id) => document.getElementById(id);

const state = {
  asyncTimer: null,
};

const els = {
  heroStatus: $('heroStatus'),
  primaryAction: $('primaryAction'),
  doubleAction: $('doubleAction'),
  hoverAction: $('hoverAction'),
  customCardAction: $('customCardAction'),
  emailField: $('emailField'),
  projectField: $('projectField'),
  notesField: $('notesField'),
  prioritySelect: $('prioritySelect'),
  termsCheckbox: $('termsCheckbox'),
  planBasic: $('planBasic'),
  planPro: $('planPro'),
  formState: $('formState'),
  keyboardTarget: $('keyboardTarget'),
  mousePad: $('mousePad'),
  mouseState: $('mouseState'),
  keyState: $('keyState'),
  asyncText: $('asyncText'),
  timerState: $('timerState'),
  revealAsyncButton: $('revealAsyncButton'),
  scrollBox: $('scrollBox'),
  dragSource: $('dragSource'),
  dragTarget: $('dragTarget'),
  dragState: $('dragState'),
  uploadField: $('uploadField'),
  uploadState: $('uploadState'),
  alertButton: $('alertButton'),
  confirmButton: $('confirmButton'),
  promptButton: $('promptButton'),
  dialogState: $('dialogState'),
  seedStorageButton: $('seedStorageButton'),
  storageState: $('storageState'),
  fetchInfoButton: $('fetchInfoButton'),
  fetchSlowButton: $('fetchSlowButton'),
  networkState: $('networkState'),
};

window.fixtureReady = false;

function selectedPlan() {
  return els.planPro.checked ? 'pro' : 'basic';
}

function updateFormState() {
  const payload = {
    email: els.emailField.value,
    project: els.projectField.value,
    notes: els.notesField.value,
    priority: els.prioritySelect.value,
    terms: els.termsCheckbox.checked,
    plan: selectedPlan(),
  };
  els.formState.textContent = JSON.stringify(payload, null, 2);
}

function refreshStorageState() {
  const local = Object.fromEntries(Object.keys(localStorage).sort().map((key) => [key, localStorage.getItem(key)]));
  const session = Object.fromEntries(Object.keys(sessionStorage).sort().map((key) => [key, sessionStorage.getItem(key)]));
  els.storageState.textContent = JSON.stringify({
    local,
    session,
    cookie: document.cookie,
  }, null, 2);
}

function seedStorage() {
  localStorage.setItem('fixture.theme', 'copper');
  localStorage.setItem('fixture.user', 'agent');
  sessionStorage.setItem('fixture.session', 'active');
  document.cookie = 'fixture_cookie=ready; path=/';
  refreshStorageState();
  els.heroStatus.textContent = 'storage seeded';
}

function revealAsyncContent() {
  window.fixtureReady = false;
  els.asyncText.classList.add('hidden');
  els.timerState.textContent = 'timer: scheduled';
  if (state.asyncTimer)
    window.clearTimeout(state.asyncTimer);
  state.asyncTimer = window.setTimeout(() => {
    window.fixtureReady = true;
    els.asyncText.classList.remove('hidden');
    els.timerState.textContent = 'timer: completed';
  }, 900);
}

function setNetworkState(payload) {
  els.networkState.textContent = JSON.stringify(payload, null, 2);
}

els.primaryAction.addEventListener('click', () => {
  els.heroStatus.textContent = 'primary action clicked';
});

els.doubleAction.addEventListener('dblclick', () => {
  els.heroStatus.textContent = 'double action activated';
});

els.hoverAction.addEventListener('mouseenter', () => {
  els.heroStatus.textContent = 'hover marker entered';
});

els.customCardAction.addEventListener('click', () => {
  els.heroStatus.textContent = 'custom card activated';
});

[els.emailField, els.projectField, els.notesField, els.prioritySelect, els.termsCheckbox, els.planBasic, els.planPro].forEach((el) => {
  el.addEventListener('input', updateFormState);
  el.addEventListener('change', updateFormState);
});

els.keyboardTarget.addEventListener('keydown', (event) => {
  els.keyState.textContent = `key: down ${event.key}`;
});

els.keyboardTarget.addEventListener('keyup', (event) => {
  els.keyState.textContent = `key: up ${event.key}`;
});

els.mousePad.addEventListener('mousemove', (event) => {
  els.mouseState.textContent = `mouse: move ${event.offsetX},${event.offsetY}`;
});

els.mousePad.addEventListener('mousedown', () => {
  els.mouseState.textContent = 'mouse: down';
});

els.mousePad.addEventListener('mouseup', () => {
  els.mouseState.textContent = 'mouse: up';
});

els.mousePad.addEventListener('wheel', (event) => {
  els.mouseState.textContent = `mouse: wheel ${Math.round(event.deltaY)}`;
}, { passive: true });

els.revealAsyncButton.addEventListener('click', revealAsyncContent);

els.dragSource.addEventListener('dragstart', (event) => {
  event.dataTransfer?.setData('text/plain', 'fixture-card');
  els.dragState.textContent = 'drag: started';
});

els.dragTarget.addEventListener('dragover', (event) => {
  event.preventDefault();
  els.dragState.textContent = 'drag: over target';
});

els.dragTarget.addEventListener('drop', (event) => {
  event.preventDefault();
  const payload = event.dataTransfer?.getData('text/plain') || 'unknown';
  els.dragState.textContent = `drag: dropped ${payload}`;
});

els.uploadField.addEventListener('change', () => {
  const names = Array.from(els.uploadField.files || []).map((file) => file.name);
  els.uploadState.textContent = names.length > 0 ? `upload: ${names.join(', ')}` : 'upload: none';
});

els.alertButton.addEventListener('click', () => {
  window.alert('fixture alert');
  els.dialogState.textContent = 'dialog: alert handled';
});

els.confirmButton.addEventListener('click', () => {
  const accepted = window.confirm('fixture confirm');
  els.dialogState.textContent = `dialog: confirm ${accepted ? 'accepted' : 'dismissed'}`;
});

els.promptButton.addEventListener('click', () => {
  const value = window.prompt('fixture prompt', 'prefilled');
  els.dialogState.textContent = `dialog: prompt ${value === null ? 'dismissed' : value}`;
});

els.seedStorageButton.addEventListener('click', seedStorage);

els.fetchInfoButton.addEventListener('click', async () => {
  setNetworkState({ status: 'loading', endpoint: '/api/demo/request-info' });
  const response = await fetch('/api/demo/request-info', {
    headers: {
      'X-Fixture-Client': 'lab',
    },
  });
  const data = await response.json();
  setNetworkState(data);
});

els.fetchSlowButton.addEventListener('click', async () => {
  setNetworkState({ status: 'loading', endpoint: '/api/demo/slow' });
  const response = await fetch('/api/demo/slow');
  const data = await response.json();
  setNetworkState(data);
});

updateFormState();
seedStorage();
revealAsyncContent();