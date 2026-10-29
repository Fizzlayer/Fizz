/* A self-contained sample workspace. No auth, API requests, or real notifications. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const kinds = window.fizzKinds;
  const seeds = [
    { id: 'cold-room', name: 'Cold Room', kind: 'temperature', zone: 'storage', base: 4.8, amplitude: .3, description: 'A temperature probe in cold storage. The sample watch list alerts when this room rises above 8 °C.' },
    { id: 'greenhouse', name: 'Greenhouse', kind: 'humidity', zone: 'greenhouse', base: 64, amplitude: 1.6, description: 'Humidity around the plants. A sample alert watches for readings below 45%.' },
    { id: 'warehouse', name: 'Warehouse', kind: 'temperature', zone: 'storage', base: 21.6, amplitude: .5, description: 'Ambient temperature on the warehouse floor, shown alongside the cold room in the Storage filter.' },
    { id: 'basement', name: 'Basement', kind: 'water', zone: 'storage', base: 0, amplitude: 0, description: 'A water flow sensor below the storage area. Zero flow means no water is moving in this sample.' },
    { id: 'office-air', name: 'Office Air', kind: 'gas', zone: 'office', base: 418, amplitude: 9, description: 'Sample carbon dioxide concentration from the office, in parts per million. Compare it with storage and greenhouse readings in one workspace.' },
    { id: 'grow-room', name: 'Grow Room', kind: 'temperature', zone: 'greenhouse', base: 23.4, amplitude: .4, description: 'A second greenhouse reading to show temperature and humidity together.' },
  ];
  let sensors, rules, events, tick, incident, paused, filter, busy, generation = 0;
  let responseTimer;
  const valueText = (sensor) => kinds.formatValue(sensor.value, kinds.get(sensor.kind).unit);
  const sensorFor = (id) => sensors.find((sensor) => sensor.id === id);
  const breached = (rule) => rule.enabled && (rule.comparator === 'gt' ? sensorFor(rule.sensorId).value > rule.threshold : sensorFor(rule.sensorId).value < rule.threshold);

  function el(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }

  function trend(sensor, detail = false) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 320 70');
    svg.setAttribute('preserveAspectRatio', 'none');
    svg.setAttribute('class', 'sensor-trend');
    svg.style.setProperty('--sensor-color', kinds.get(sensor.kind).color);
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', `${sensor.name}: ${sensor.history.length} simulated readings, now ${valueText(sensor)}.`);
    const values = sensor.history;
    const min = Math.min(...values) - .2;
    const range = Math.max(...values) - min + .2;
    const path = document.createElementNS(svg.namespaceURI, 'path');
    path.setAttribute('d', values.map((value, index) => `${index ? 'L' : 'M'}${(3 + index * 314 / (values.length - 1)).toFixed(1)},${(64 - (value - min) / range * 58).toFixed(1)}`).join(' '));
    for (const [key, value] of Object.entries({ fill: 'none', stroke: 'currentColor', 'stroke-width': detail ? '2.5' : '1.8', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'vector-effect': 'non-scaling-stroke' })) path.setAttribute(key, value);
    svg.append(path);
    return svg;
  }

  function renderSensors() {
    // Keep card nodes stable while readings update, preserving keyboard focus.
    for (const sensor of sensors) {
      const card = $(`sensor-${sensor.id}`);
      card.hidden = filter !== 'all' && sensor.zone !== filter;
      card.classList.toggle('incident', rules.some((rule) => rule.sensorId === sensor.id && breached(rule)));
      card.querySelector('.live-value').textContent = valueText(sensor);
      card.querySelector('.sensor-trend').replaceWith(trend(sensor));
    }
    $('demo-updated').textContent = paused ? 'SAMPLE STREAM PAUSED' : `SAMPLE STREAM · UPDATED ${new Date().toLocaleTimeString()}`;
  }

  function buildSensors() {
    $('demo-sensors').replaceChildren();
    $('rule-sensor').replaceChildren();
    for (const sensor of sensors) {
      const info = kinds.get(sensor.kind);
      const card = el('button', 'live-card');
      card.type = 'button';
      card.id = `sensor-${sensor.id}`;
      card.setAttribute('aria-label', `Explore ${sensor.name} sample readings`);
      card.style.setProperty('--sensor-color', info.color);
      const top = el('div', 'live-card-top');
      const title = el('div', 'live-card-title');
      title.append(el('h3', '', sensor.name), el('span', '', info.label.toUpperCase()));
      top.append(kinds.badge(sensor.kind), title, el('span', 'mode-pill simulated', 'SAMPLE'));
      const foot = el('div', 'live-foot');
      foot.append(el('span', '', sensor.zone === 'office' ? 'Office' : sensor.zone === 'storage' ? 'Storage' : 'Greenhouse'), el('span', '', 'Explore ↗'));
      card.append(top, el('p', 'live-metric', sensor.kind === 'gas' ? 'CO₂ concentration' : kinds.metricLabel(info.metric)), el('p', 'live-value', valueText(sensor)), trend(sensor), foot);
      card.addEventListener('click', () => {
        $('detail-title').textContent = sensor.name;
        $('detail-value').textContent = valueText(sensor);
        $('detail-chart').replaceChildren(trend(sensor, true));
        $('detail-description').textContent = sensor.description;
        $('sensor-dialog').showModal();
      });
      $('demo-sensors').append(card);
      const option = el('option', '', `${sensor.name} (${info.unit})`);
      option.value = sensor.id;
      $('rule-sensor').append(option);
    }
  }

  function ruleDescription(rule) {
    const sensor = sensorFor(rule.sensorId);
    return `${sensor.name} ${rule.comparator === 'gt' ? 'above' : 'below'} ${kinds.formatValue(rule.threshold, kinds.get(sensor.kind).unit)}`;
  }

  function callPreview(event) {
    $('call-transcript').textContent = `“Hi, this is Fizz from your Harbor & Pine demo workspace. ${event.name} is reading ${event.value}. Your alert is set for ${event.description}. Please check the sensor and the space.”`;
    $('call-dialog').showModal();
  }

  function renderAlerts() {
    const focused = document.activeElement;
    const focusKey = focused?.dataset.ruleAction ? [focused.dataset.ruleAction, focused.dataset.ruleId] : null;
    $('demo-rules').replaceChildren();
    const active = rules.filter((rule) => rule.enabled);
    const triggered = rules.filter(breached);
    $('enabled-count').textContent = active.length;
    $('workspace-health').textContent = triggered.length ? 'Needs a look' : 'All clear';
    $('workspace-health').classList.toggle('incident', triggered.length > 0);
    $('health-detail').textContent = triggered.length ? `${triggered.length} threshold alert${triggered.length === 1 ? '' : 's'} triggered` : 'Readings within their limits';
    $('alert-summary').textContent = triggered.length ? `${triggered.length} triggered` : `${active.length} watching`;
    $('alert-summary').className = `alert-chip ${triggered.length ? 'triggered' : 'watching'}`;
    for (const rule of rules) {
      const status = !rule.enabled ? 'paused' : breached(rule) ? 'triggered' : 'watching';
      const item = el('li', `alert-item demo-rule ${status}`);
      const head = el('div', 'alert-item-head');
      head.append(el('strong', '', sensorFor(rule.sensorId).name), el('span', `alert-status ${status}`, status.toUpperCase()));
      const actions = el('div', 'alert-actions');
      const buttons = el('div');
      for (const action of ['toggle', 'delete']) {
        const button = el('button', action === 'delete' ? 'alert-delete' : 'secondary', action === 'delete' ? 'Delete' : rule.enabled ? 'Pause' : 'Resume');
        button.type = 'button';
        button.dataset.ruleAction = action;
        button.dataset.ruleId = rule.id;
        button.setAttribute('aria-label', `${action === 'toggle' ? (rule.enabled ? 'Pause' : 'Resume') : 'Delete'} alert: ${ruleDescription(rule)}`);
        button.addEventListener('click', () => {
          if (action === 'delete') rules = rules.filter((item) => item.id !== rule.id);
          else rule.enabled = !rule.enabled;
          evaluateRules();
          renderAlerts();
          renderSensors();
          if (action === 'delete') $('alert-builder').querySelector('summary').focus();
        });
        buttons.append(button);
      }
      actions.append(el('span', '', rule.notification === 'call' ? 'Phone call preview · shift lead' : 'Dashboard notification'), buttons);
      item.append(head, el('p', 'alert-line', `Alert when ${ruleDescription(rule)}.`), actions);
      $('demo-rules').append(item);
    }
    if (!rules.length) $('demo-rules').append(el('li', 'dashboard-empty', 'No demo alerts. Create one below.'));
    $('demo-events').replaceChildren();
    for (const event of events.slice(0, 3)) {
      const item = el('div', 'demo-event');
      item.append(el('strong', '', `${event.name} crossed its threshold`), el('p', '', `${event.value} · ${event.description} · ${event.notification === 'call' ? 'Simulated phone alert ready' : 'Demo dashboard alert'}`));
      if (event.notification === 'call') {
        const button = el('button', 'secondary', 'Preview the call ↗');
        button.type = 'button';
        button.addEventListener('click', () => callPreview(event));
        item.append(button);
      }
      $('demo-events').append(item);
    }
    if (focusKey) $('demo-rules').querySelector(`[data-rule-action="${focusKey[0]}"][data-rule-id="${focusKey[1]}"]`)?.focus({ preventScroll: true });
  }

  function evaluateRules() {
    for (const rule of rules) {
      const met = breached(rule);
      if (met && !rule.triggered) {
        const sensor = sensorFor(rule.sensorId);
        events.unshift({ name: sensor.name, value: valueText(sensor), description: ruleDescription(rule), notification: rule.notification });
        events = events.slice(0, 12);
      }
      rule.triggered = met;
    }
  }

  function addRule(sensorId, comparator, threshold, notification) {
    const duplicate = rules.some((rule) => rule.sensorId === sensorId && rule.comparator === comparator && rule.threshold === threshold && rule.enabled && rule.notification === notification);
    if (duplicate) return false;
    rules.push({ id: `rule-${generation}-${++tick}`, sensorId, comparator, threshold, notification, enabled: true, triggered: false });
    evaluateRules();
    renderAlerts();
    renderSensors();
    return true;
  }

  function message(role, text) {
    const item = el('div', `chat-message ${role}`);
    item.append(el('span', '', role === 'user' ? 'YOU' : 'FIZZ · DEMO'), el('p', '', text));
    $('demo-chat').append(item);
    while ($('demo-chat').children.length > 16) $('demo-chat').firstElementChild.remove();
    $('demo-chat').scrollTop = $('demo-chat').scrollHeight;
    return item;
  }

  function answer(question) {
    const text = question.toLowerCase();
    const cold = sensorFor('cold-room');
    if (/(set|create|add|alert me|watch.*above)/.test(text) && /(alert|watch)/.test(text)) {
      const match = text.match(/(above|below|over|under)\s*(-?\d+(?:\.\d+)?)/);
      if (!match) return 'Try “Alert me if the cold room goes above 7 °C”, or use the threshold form below. Any phone notification here is a preview.';
      const sensor = /humid/.test(text) ? sensorFor('greenhouse') : /grow/.test(text) ? sensorFor('grow-room') : /warehouse/.test(text) ? sensorFor('warehouse') : /water|basement/.test(text) ? sensorFor('basement') : /air|co2|co₂/.test(text) ? sensorFor('office-air') : cold;
      const comparator = /below|under/.test(match[1]) ? 'lt' : 'gt';
      const threshold = Number(match[2]);
      const notification = /call|phone/.test(text) ? 'call' : 'dashboard';
      const created = addRule(sensor.id, comparator, threshold, notification);
      return `${created ? 'Demo alert created' : 'That demo alert is already watching'}: ${sensor.name} ${comparator === 'gt' ? 'above' : 'below'} ${kinds.formatValue(threshold, kinds.get(sensor.kind).unit)}. ${notification === 'call' ? 'It will show a simulated phone alert.' : 'It will appear in Alerts & activity.'}`;
    }
    if (/alert|watch list|watching|threshold/.test(text)) return rules.length ? `Your sample watch list: ${rules.map((rule) => `${ruleDescription(rule)} (${rule.enabled ? breached(rule) ? 'triggered' : 'watching' : 'paused'})`).join('; ')}. Use “Simulate temperature spike” to try the cold room alert.` : 'Your sample watch list is empty. Create a threshold alert below to try it.';
    if (/cold|spike|warm/.test(text)) return `Cold Room is ${valueText(cold)} in the sample workspace. ${incident ? 'The temperature spike is active. Check Alerts & activity for any thresholds crossed; you can also preview the sample phone call.' : 'It is below the default 8 °C alert threshold. Its recent sample readings are steady. Try simulating a spike to see what happens.'}`;
    if (/greenhouse|plant|humid|grow/.test(text)) return `In the sample greenhouse, humidity is ${valueText(sensorFor('greenhouse'))} and the grow room is ${valueText(sensorFor('grow-room'))}. The sample humidity alert watches for a drop below 45%.`;
    if (/water|basement|leak/.test(text)) return `Basement flow is ${valueText(sensorFor('basement'))} in this sample. The simulated history shows no water flow. You can create an alert above 0 L/min to watch for a change.`;
    if (/air|co2|co₂|office/.test(text)) return `Office Air shows a sample CO₂ concentration of ${valueText(sensorFor('office-air'))}. Open its sensor card to explore the recent simulated history.`;
    if (/warehouse/.test(text)) return `Warehouse temperature is ${valueText(sensorFor('warehouse'))}. Use the Storage filter to compare it with the Cold Room and Basement readings.`;
    if (/summary|summari[sz]e|sensor|happening|status|overview/.test(text)) return `Here is your sample workspace: Cold Room ${valueText(cold)}, Warehouse ${valueText(sensorFor('warehouse'))}, Greenhouse ${valueText(sensorFor('greenhouse'))}, Grow Room ${valueText(sensorFor('grow-room'))}, Basement ${valueText(sensorFor('basement'))}, and Office Air ${valueText(sensorFor('office-air'))}. ${rules.filter(breached).length ? 'A threshold needs attention — see Alerts & activity.' : 'No enabled threshold is currently crossed.'}`;
    return 'I can walk you through this sample workspace. Ask about the cold room, greenhouse, water flow, or watch list. Try “Alert me if the cold room goes above 7 °C.” Demo replies use these sample readings.';
  }

  function setBusy(value) {
    busy = value;
    $('demo-chat-input').disabled = value;
    $('demo-chat-form').querySelector('button').disabled = value;
    for (const button of document.querySelectorAll('[data-prompt]')) button.disabled = value;
  }

  function ask(question) {
    if (busy || !question) return;
    const version = generation;
    message('user', question);
    const pending = message('agent', 'Checking the sample readings…');
    pending.classList.add('thinking');
    setBusy(true);
    responseTimer = setTimeout(() => {
      if (generation !== version) return;
      pending.querySelector('p').textContent = answer(question);
      pending.classList.remove('thinking');
      setBusy(false);
      $('demo-chat').scrollTop = $('demo-chat').scrollHeight;
    }, 650);
  }

  function update() {
    tick++;
    for (const [index, sensor] of sensors.entries()) {
      sensor.value = sensor.id === 'cold-room' && incident ? 9.2 : Math.max(0, Math.round((sensor.base + Math.sin(tick * .7 + index) * sensor.amplitude) * 10) / 10);
      sensor.history.push(sensor.value);
      sensor.history = sensor.history.slice(-24);
    }
    evaluateRules();
    renderSensors();
    renderAlerts();
  }

  function reset() {
    generation++;
    clearTimeout(responseTimer);
    tick = 0; incident = false; paused = false; filter = 'all'; events = [];
    sensors = seeds.map((seed, index) => ({ ...seed, value: seed.base, history: Array.from({ length: 24 }, (_, i) => Math.max(0, Math.round((seed.base + Math.sin(i * .55 + index) * seed.amplitude) * 10) / 10)) }));
    rules = [
      { id: 'cold-default', sensorId: 'cold-room', comparator: 'gt', threshold: 8, notification: 'call', enabled: true, triggered: false },
      { id: 'humidity-default', sensorId: 'greenhouse', comparator: 'lt', threshold: 45, notification: 'dashboard', enabled: true, triggered: false },
    ];
    for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close();
    for (const button of document.querySelectorAll('[data-filter]')) button.setAttribute('aria-pressed', String(button.dataset.filter === 'all'));
    $('pause-demo').textContent = 'Pause readings';
    $('pause-demo').setAttribute('aria-pressed', 'false');
    $('stream-status').textContent = 'Sample stream running';
    $('simulate-spike').textContent = 'Simulate temperature spike ↗';
    $('scenario-result').hidden = true;
    document.querySelector('.demo-scenario').classList.remove('incident');
    $('rule-message').textContent = '';
    $('demo-alert-form').reset();
    $('alert-builder').open = false;
    $('demo-chat-input').value = '';
    $('demo-chat').replaceChildren();
    setBusy(false);
    message('agent', 'Hi, I’m Fizz. This sample workspace has a cold room, a greenhouse, and an office. Ask me what the sensors are seeing, or try a temperature spike.');
    buildSensors();
    renderSensors();
    renderAlerts();
  }

  for (const button of document.querySelectorAll('[data-filter]')) button.addEventListener('click', () => {
    filter = button.dataset.filter;
    for (const filterButton of document.querySelectorAll('[data-filter]')) filterButton.setAttribute('aria-pressed', String(filterButton === button));
    renderSensors();
  });
  for (const button of document.querySelectorAll('[data-prompt]')) button.addEventListener('click', () => ask(button.dataset.prompt));
  $('demo-chat-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const text = $('demo-chat-input').value.trim();
    if (!text || busy) return;
    $('demo-chat-input').value = '';
    ask(text);
  });
  $('simulate-spike').addEventListener('click', () => {
    incident = !incident;
    $('simulate-spike').textContent = incident ? 'Resolve temperature spike ↗' : 'Simulate temperature spike ↗';
    $('scenario-result').hidden = !incident;
    document.querySelector('.demo-scenario').classList.toggle('incident', incident);
    update();
  });
  $('pause-demo').addEventListener('click', () => {
    paused = !paused;
    $('pause-demo').textContent = paused ? 'Resume readings' : 'Pause readings';
    $('pause-demo').setAttribute('aria-pressed', String(paused));
    $('stream-status').textContent = paused ? 'Sample stream paused' : 'Sample stream running';
    renderSensors();
  });
  $('reset-demo').addEventListener('click', reset);
  $('demo-alert-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const threshold = Number($('rule-threshold').value);
    if (!Number.isFinite(threshold)) return;
    const created = addRule($('rule-sensor').value, $('rule-comparator').value, threshold, $('rule-notification').value);
    $('rule-message').textContent = created ? 'Demo alert created. Try a temperature spike to see it trigger.' : 'That demo alert already exists in your watch list.';
  });
  for (const button of document.querySelectorAll('[data-close-dialog]')) button.addEventListener('click', () => button.closest('dialog').close());
  for (const link of document.querySelectorAll('.dashboard-bar nav a')) link.addEventListener('click', () => {
    for (const other of document.querySelectorAll('.dashboard-bar nav a')) other.classList.toggle('active', other === link);
  });
  reset();
  setInterval(() => { if (!paused && !document.hidden) update(); }, 3000);
})();
