/**
 * Client half of dsh-status-box.
 *
 * One visible surface and one headless bridge, both riding the shipped slot
 * system:
 *  - `conversation.header.leading`  a compact status pill in the window's own
 *                    top bar (before the Session title, mounted with or
 *                    without a Session): aggregate running / waiting / done
 *                    counts for every workspace. Clicking it summons the
 *                    native capture window (or sends /nudge when the macOS
 *                    companion is not running).
 *  - `shell.overlay`  a headless reporter: pushes the aggregate to the macOS
 *                    menu-bar companion (127.0.0.1:59421) and polls its task
 *                    queue, so a task typed while DSH was closed still starts.
 *
 * Data comes only from the slot scope hooks (useWorkspaces / useSessions /
 * useSessionStatus) that both seats project. Task start uses the Client
 * `uiWorkspace.connectWorkspace` + `sessions.using(...)` path so the turn
 * begins in a real session without navigating the main view.
 */
window.__ModuleLoader__.load({
  id: 'dsh-status-box',
  factory: (require) => {
    const React = require('react');
    const h = React.createElement;
    const NS = 'dsh-status-box';
    const HOTKEY_KEY = 'k';
    const REFRESH_MS = 30000;

    // macOS menu-bar companion (menubar/main.m). It cannot see the frame, so the
    // client pushes the aggregate it already computes and polls for "summon".
    const BRIDGE_BASE = 'http://127.0.0.1:59421';
    const BRIDGE_HEARTBEAT_MS = 8000;
    const BRIDGE_COMMAND_MS = 2000;

    // The bridge entry is deliberately headless, so the factory hands it the
    // task starter directly; every task id is delivered at most once per frame.
    const taskSink = { startTask: null, openSession: null };
    // Task ids already handed to this frame. Bounded twice over: entries expire
    // after a few minutes and the list never grows past a small cap, so a long
    // lived window cannot leak memory (the companion retries an un-acked task
    // for 45 s, so a 5 minute window is plenty).
    const bridgeSeenTasks = [];
    const TASK_DEDUPE_MS = 5 * 60 * 1000;
    const TASK_DEDUPE_MAX = 100;

    //#region locale dictionaries
    const zh = {
      'bar.running': '{n} 运行中',
      'bar.waiting': '{n} 待处理',
      'bar.done': '{n} 已完成',
      'bar.idle': '空闲',
      'bar.active': '{n} 个进行中',
      'bar.tip': '点击召唤输入窗 · ⌘⇧K',
      'settings.title': '状态盒',
      'settings.desc': '控制从悬浮窗发起任务之后发生什么。',
      'settings.openOnSend': '发送后打开对话页',
      'settings.openOnSendHint': '关掉就留在原地继续忙手头的事，任务照样在后台开跑。',
      'settings.offline': '没连上菜单栏小助手（状态盒）。先运行 menubar/install.sh，或重启一次 DSH。',
      'settings.retry': '重试',
      'settings.install': '安装菜单栏小助手',
      'settings.installing': '正在安装…',
      'settings.installed': '已安装，正在连接…',
      'settings.installFailed': '安装失败：{reason}',
      'settings.copyCommand': '复制安装命令',
      'settings.copied': '已复制',
      'settings.notMac': '菜单栏小助手目前只支持 macOS。',
      'time.now': '刚刚',
      'time.m': '{n} 分钟前',
      'time.h': '{n} 小时前',
      'time.d': '{n} 天前'
    };
    const en = {
      'bar.running': '{n} running',
      'bar.waiting': '{n} waiting',
      'bar.done': '{n} done',
      'bar.idle': 'Idle',
      'bar.active': '{n} active',
      'bar.tip': 'Click to summon the capture window · ⌘⇧K',
      'settings.title': 'Status Box',
      'settings.desc': 'Choose what happens after you send a task from the floating window.',
      'settings.openOnSend': 'Open the conversation after sending',
      'settings.openOnSendHint': 'Turn it off to stay where you are: the task still starts in the background.',
      'settings.offline': 'The menu-bar companion is not reachable. Run menubar/install.sh, or restart DSH.',
      'settings.retry': 'Retry',
      'settings.install': 'Install menu-bar companion',
      'settings.installing': 'Installing…',
      'settings.installed': 'Installed — connecting…',
      'settings.installFailed': 'Install failed: {reason}',
      'settings.copyCommand': 'Copy install command',
      'settings.copied': 'Copied',
      'settings.notMac': 'The menu-bar companion is macOS only.',
      'time.now': 'just now',
      'time.m': '{n}m ago',
      'time.h': '{n}h ago',
      'time.d': '{n}d ago'
    };
    //#endregion

    //#region styles
    const CSS = [
      '.qd-pill{display:inline-flex;align-items:center;gap:9px;height:22px;max-width:min(44vw,330px);padding:0 9px;box-sizing:border-box;border:1px solid var(--dsw-alias-border-l1,#e9eaed);border-radius:999px;background:var(--dsw-alias-bg-layer-2,#f1f3f6);color:var(--dsw-alias-label-secondary,#6b7280);font:11px/1 var(--ds-font-family-sans,system-ui,-apple-system,"Segoe UI",sans-serif);cursor:pointer;white-space:nowrap;overflow:hidden;user-select:none;flex:none;margin:0 2px}',
      '.qd-pill:hover{border-color:var(--dsw-alias-border-l2,#dfe3e8);color:var(--dsw-alias-label-primary,#111827)}',
      '.qd-pill-stat{display:inline-flex;align-items:center;gap:4px;flex:none}',
      '.qd-pill-count{font-variant-numeric:tabular-nums}',
      '.qd-pill-muted{color:var(--dsw-alias-label-secondary,#9ca3af)}',
      '.qd-dot{width:7px;height:7px;border-radius:50%;flex:none;background:var(--dsw-alias-state-idle-primary,#9ca3af)}',
      '.qd-dot.state-waiting{background:var(--dsw-alias-state-warn-primary,#d97706)}',
      '.qd-dot.state-running{background:var(--dsw-alias-state-success-primary,#16a34a)}',
      '.qd-dot.state-done{background:var(--dsw-alias-brand-primary,#4f6ef7)}',
      '.qd-head{display:flex;align-items:center;gap:8px;padding:9px 12px 7px;border-bottom:1px solid var(--dsw-alias-border-l1,#eef1f5)}',
      '.qd-title{font-size:13px;font-weight:600;white-space:nowrap}',
      '.qd-icon-btn{margin-left:auto;flex:none;display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;border:0;border-radius:6px;background:transparent;color:var(--dsw-alias-label-secondary,#6b7280);cursor:pointer;font-size:15px;line-height:1}',
      '.qd-icon-btn:hover{background:var(--dsw-alias-bg-layer-2,#f1f3f6);color:var(--dsw-alias-label-primary,#111827)}',
      '.qd-settings{display:flex;flex-direction:column;gap:14px;padding:4px 2px 8px;max-width:560px;font:13px/1.55 var(--ds-font-family-sans,system-ui,-apple-system,"Segoe UI",sans-serif);color:var(--dsw-alias-label-primary,#111827)}',
      '.qd-settings-title{font-size:15px;font-weight:600;margin:0}',
      '.qd-settings-desc{margin:0;color:var(--dsw-alias-label-secondary,#6b7280)}',
      '.qd-settings-row{display:flex;align-items:center;gap:12px;padding:10px 12px;border:1px solid var(--dsw-alias-border-l1,#e9eaed);border-radius:10px;background:var(--dsw-alias-bg-layer-1,#fff)}',
      '.qd-settings-label{display:flex;flex-direction:column;gap:2px;flex:1 1 auto;min-width:0}',
      '.qd-settings-hint{margin:0;color:var(--dsw-alias-label-secondary,#6b7280);font-size:12px}',
      '.qd-settings-note{margin:0;color:var(--dsw-alias-state-warn-primary,#d97706);font-size:12px}',
      '.qd-retry{margin-left:6px;padding:0;border:none;background:none;color:var(--dsw-alias-brand-primary,#4f6ef7);font:inherit;font-size:12px;cursor:pointer;text-decoration:underline}',
      '.qd-retry:hover{opacity:.8}',
      '.qd-settings-detail{opacity:.75}',
      '.qd-switch{flex:none;position:relative;width:38px;height:22px;padding:0;border-radius:999px;border:1px solid var(--dsw-alias-border-l2,#dfe3e8);background:var(--dsw-alias-bg-layer-2,#f1f3f6);cursor:pointer;transition:background .15s,border-color .15s}',
      '.qd-switch.on{background:var(--dsw-alias-brand-primary,#4f6ef7);border-color:var(--dsw-alias-brand-primary,#4f6ef7)}',
      '.qd-switch:disabled{cursor:default;opacity:.5}',
      '.qd-switch-knob{position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25);transition:transform .15s}',
      '.qd-switch.on .qd-switch-knob{transform:translateX(16px)}',
    ].join('\n');

    function insertStyles(css, owner) {
      if (typeof document === 'undefined' || document.head === null) return function () {};
      const selector = 'style[data-quick-desk="' + owner + '"]';
      const stale = document.querySelectorAll(selector);
      for (let index = 0; index < stale.length; index += 1) stale[index].remove();
      const tag = document.createElement('style');
      tag.dataset.quickDesk = owner;
      tag.textContent = css;
      document.head.appendChild(tag);
      return function () {
        tag.remove();
      };
    }
    //#endregion

    //#region data model
    const RANK = { waiting: 0, running: 1, done: 2, idle: 3 };
    const EMPTY_SNAPSHOT = { items: [], archivedSessionIds: [], pinnedSessionIds: [] };
    const EMPTY_LIST = { ids: [], byId: {} };

    function useNoSnapshot() {
      return undefined;
    }


    function useTick(intervalMs) {
      const [now, setNow] = React.useState(function () {
        return Date.now();
      });
      React.useEffect(
        function () {
          const timer = setInterval(function () {
            setNow(Date.now());
          }, intervalMs);
          return function () {
            clearInterval(timer);
          };
        },
        [intervalMs]
      );
      return now;
    }

    function stateOf(status, session) {
      if (status !== undefined && status !== null && status.pendingInteraction !== undefined && status.pendingInteraction !== null) {
        const kind = status.pendingInteraction.kind;
        if (kind === 'approval' || kind === 'plan-review' || kind === 'question') return 'waiting';
        return 'waiting';
      }
      const running = status === undefined || status === null || status.running === undefined ? Boolean(session && session.running) : status.running === true;
      if (running) return 'running';
      if (status !== undefined && status !== null && status.completionUnread === true) return 'done';
      return 'idle';
    }

    function toRow(session, list, statuses) {
      const status = statuses && typeof statuses.get === 'function' ? statuses.get(session.id) : undefined;
      const state = stateOf(status, session);
      const catalog = list && list.projectionsBySession && list.projectionsBySession[session.id]
        ? list.projectionsBySession[session.id].values && list.projectionsBySession[session.id].values.subagentCatalog
        : undefined;
      let subagents = 0;
      let runningSubagents = 0;
      if (Array.isArray(catalog)) {
        subagents = catalog.length;
        for (let index = 0; index < catalog.length; index += 1) {
          const child = catalog[index];
          if (child === undefined || child === null) continue;
          const childStatus = statuses && typeof statuses.get === 'function' ? statuses.get(child.id) : undefined;
          const childRunning = childStatus !== undefined && childStatus !== null && childStatus.running !== undefined
            ? childStatus.running === true
            : Boolean(list && list.byId && list.byId[child.id] ? list.byId[child.id].running : false);
          if (childRunning) runningSubagents += 1;
        }
      }
      return {
        id: session.id,
        title: session.title === undefined || session.title === null ? '' : String(session.title),
        state,
        stateRank: RANK[state],
        subagents,
        runningSubagents,
        updatedAt: typeof session.updatedAt === 'number' ? session.updatedAt : 0
      };
    }

    function visibleSession(session, archived) {
      if (session === undefined || session === null) return false;
      if (session.origin === 'subagent') return false;
      if (session.blank === true) return false;
      if (archived.has(session.id)) return false;
      return true;
    }

    function makeGroup(id, title, rows, now) {
      const counts = { waiting: 0, running: 0, done: 0, idle: 0 };
      for (let index = 0; index < rows.length; index += 1) counts[rows[index].state] += 1;
      const rank = rows.reduce(function (lowest, row) {
        return row.stateRank < lowest ? row.stateRank : lowest;
      }, 3);
      const updatedAt = rows.reduce(function (newest, row) {
        return row.updatedAt > newest ? row.updatedAt : newest;
      }, 0);
      return { id, title, rows, counts, rank, updatedAt, now };
    }

    function aggregate(snapshot, list, statuses, now) {
      const source = snapshot === undefined || snapshot === null ? EMPTY_SNAPSHOT : snapshot;
      const sessions = list === undefined || list === null ? EMPTY_LIST : list;
      const byId = sessions.byId === undefined || sessions.byId === null ? {} : sessions.byId;
      const archived = new Set(Array.isArray(source.archivedSessionIds) ? source.archivedSessionIds : []);
      const workspaces = Array.isArray(source.items) ? source.items : [];
      const groups = [];
      const accounted = new Set();

      for (let index = 0; index < workspaces.length; index += 1) {
        const workspace = workspaces[index];
        const ids = Array.isArray(workspace.sessionIds) ? workspace.sessionIds : [];
        const rows = [];
        for (let member = 0; member < ids.length; member += 1) {
          const id = ids[member];
          accounted.add(id);
          const session = byId[id];
          if (!visibleSession(session, archived)) continue;
          rows.push(toRow(session, sessions, statuses));
        }
        const title = workspace.title === undefined || workspace.title === null || workspace.title === '' ? workspace.path : workspace.title;
        groups.push(makeGroup(workspace.workspaceId, String(title === undefined || title === null ? '' : title), rows, now));
      }

      const strayRows = [];
      const ids = Array.isArray(sessions.ids) ? sessions.ids : [];
      for (let index = 0; index < ids.length; index += 1) {
        const id = ids[index];
        if (accounted.has(id)) continue;
        const session = byId[id];
        if (!visibleSession(session, archived)) continue;
        strayRows.push(toRow(session, sessions, statuses));
      }
      if (strayRows.length > 0) groups.push(makeGroup('', '', strayRows, now));

      for (let index = 0; index < groups.length; index += 1) {
        groups[index].rows.sort(function (left, right) {
          if (left.stateRank !== right.stateRank) return left.stateRank - right.stateRank;
          if (left.updatedAt !== right.updatedAt) return right.updatedAt - left.updatedAt;
          return 0;
        });
      }
      groups.sort(function (left, right) {
        if (left.rank !== right.rank) return left.rank - right.rank;
        if (left.updatedAt !== right.updatedAt) return right.updatedAt - left.updatedAt;
        return left.title.localeCompare(right.title);
      });

      const totals = { waiting: 0, running: 0, done: 0, idle: 0, total: 0 };
      for (let index = 0; index < groups.length; index += 1) {
        const counts = groups[index].counts;
        totals.waiting += counts.waiting;
        totals.running += counts.running;
        totals.done += counts.done;
        totals.idle += counts.idle;
        totals.total += groups[index].rows.length;
      }

      return {
        now,
        groups,
        totals,
        workspaces: workspaces.map(function (workspace) {
          const title = workspace.title === undefined || workspace.title === null || workspace.title === '' ? workspace.path : workspace.title;
          return { id: workspace.workspaceId, title: String(title === undefined || title === null ? '' : title) };
        })
      };
    }

    function useDockData(props) {
      const useWorkspaces = typeof props.useWorkspaces === 'function' ? props.useWorkspaces : useNoSnapshot;
      const useSessions = typeof props.useSessions === 'function' ? props.useSessions : useNoSnapshot;
      const useSessionStatus = typeof props.useSessionStatus === 'function' ? props.useSessionStatus : useNoSnapshot;
      const snapshot = useWorkspaces(function (state) {
        return state;
      });
      const list = useSessions(function (state) {
        return state;
      });
      const statuses = useSessionStatus(function (state) {
        return state;
      });
      const now = useTick(REFRESH_MS);
      return React.useMemo(
        function () {
          return aggregate(snapshot, list, statuses, now);
        },
        [snapshot, list, statuses, now]
      );
    }

    function timeText(t, updatedAt, now) {
      if (!updatedAt) return '';
      const diff = Math.max(0, now - updatedAt);
      const minutes = Math.floor(diff / 60000);
      if (minutes < 1) return t('time.now');
      if (minutes < 60) return t('time.m', { n: minutes });
      const hours = Math.floor(minutes / 60);
      if (hours < 24) return t('time.h', { n: hours });
      return t('time.d', { n: Math.floor(hours / 24) });
    }
    //#endregion

    //#region components
    function StateDot(props) {
      return h('span', { className: 'qd-dot state-' + props.state, 'aria-hidden': 'true' });
    }

    function PillStat(props) {
      return h(
        'span',
        { className: 'qd-pill-stat' },
        h(StateDot, { state: props.state }),
        h('span', null, props.label)
      );
    }

    function statusSegments(t, totals) {
      const segments = [];
      if (totals.waiting > 0) {
        segments.push(h(PillStat, { key: 'waiting', state: 'waiting', label: t('bar.waiting', { n: totals.waiting }) }));
      }
      if (totals.running > 0) {
        segments.push(h(PillStat, { key: 'running', state: 'running', label: t('bar.running', { n: totals.running }) }));
      }
      if (segments.length === 0 && totals.done > 0) {
        segments.push(h(PillStat, { key: 'done', state: 'done', label: t('bar.done', { n: totals.done }) }));
      }
      return segments;
    }

    /** Compact aggregate of every workspace, living in the window's own top bar. */
    function StatusPill(props) {
      const t = props.t;
      const desk = props.desk;
      const data = useDockData(props);
      const totals = data.totals;
      const segments = statusSegments(t, totals);
      const activeGroups = data.groups.filter(function (group) {
        return group.id !== '' && group.counts.waiting + group.counts.running > 0;
      });
      const breakdown = activeGroups.map(function (group) {
        const active = group.counts.waiting + group.counts.running;
        return group.title + ' · ' + t('bar.active', { n: active });
      });
      const tipParts = breakdown.concat([t('bar.tip')]);

      return h(
        'button',
        {
          type: 'button',
          className: 'qd-pill' + (segments.length === 0 ? ' qd-pill-muted' : ''),
          title: tipParts.join('\n'),
          onClick: function () {
            desk.summonNative();
          }
        },
        segments.length === 0 ? h(StateDot, { state: 'idle' }) : segments,
        segments.length === 0 ? h('span', null, t('bar.idle')) : null
      );
    }


    //#region menu-bar bridge
    function buildBridgePayload(data) {
      const workspaces = [];
      const sessions = [];
      for (let index = 0; index < data.groups.length; index += 1) {
        const group = data.groups[index];
        // every workspace travels, including empty ones: the native capture
        // window lets you start a task in a workspace that has no session yet
        workspaces.push({
          id: group.id,
          title: group.title,
          waiting: group.counts.waiting,
          running: group.counts.running,
          done: group.counts.done
        });
        for (let row = 0; row < group.rows.length; row += 1) {
          if (sessions.length >= 10) break;
          const item = group.rows[row];
          if (item.state === 'idle') continue;
          sessions.push({ title: item.title, state: item.state, workspace: group.title });
        }
      }

      return {
        v: 1,
        ts: Date.now(),
        totals: data.totals,
        workspaces: workspaces,
        sessions: sessions
      };
    }

    function postBridge(body) {
      try {
        if (typeof fetch !== 'function') return;
        fetch(BRIDGE_BASE + '/status', {
          method: 'POST',
          mode: 'cors',
          cache: 'no-store',
          headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
          body: body
        }).catch(function () {
          // the companion is optional: no menu bar item, nothing to report to
        });
      } catch (error) {
        // fetch unavailable in this frame
      }
    }

    function ackTask(id, ok, error) {
      try {
        if (typeof fetch !== 'function') return;
        fetch(BRIDGE_BASE + '/command/ack', {
          method: 'POST',
          mode: 'cors',
          cache: 'no-store',
          headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
          body: JSON.stringify({ id: id, ok: ok === true, error: String(error || '') })
        }).catch(function () {
          // companion offline; the task is retried after its in-flight timeout
        });
      } catch (cause) {
        // ignore
      }
    }

    /**
     * Runs one task queued in the native window. The companion marks a task
     * in-flight once it is handed out, so repeated polls cannot double-send.
     */
    function pruneSeenTasks(now) {
      for (let index = bridgeSeenTasks.length - 1; index >= 0; index -= 1) {
        if (now - bridgeSeenTasks[index].at > TASK_DEDUPE_MS) bridgeSeenTasks.splice(index, 1);
      }
    }

    function sawTask(id) {
      pruneSeenTasks(Date.now());
      for (let index = 0; index < bridgeSeenTasks.length; index += 1) {
        if (bridgeSeenTasks[index].id === id) return true;
      }
      return false;
    }

    function rememberTask(id) {
      bridgeSeenTasks.push({ id: id, at: Date.now() });
      if (bridgeSeenTasks.length > TASK_DEDUPE_MAX) {
        bridgeSeenTasks.splice(0, bridgeSeenTasks.length - TASK_DEDUPE_MAX);
      }
    }

    function deliverTask(task, data) {
      if (task === null || typeof task !== 'object') return;
      const id = task.id;
      const text = task.text;
      if (typeof id !== 'string' || id === '') return;
      if (typeof text !== 'string' || text.trim() === '') {
        ackTask(id, false, 'empty');
        return;
      }
      if (sawTask(id)) return;
      if (typeof taskSink.startTask !== 'function') return;
      rememberTask(id);
      // a workspace id cached by the companion may be gone; fall back to a
      // workspace this frame actually knows about
      let workspaceId = typeof task.workspaceId === 'string' ? task.workspaceId : '';
      if (workspaceId !== '') {
        let known = false;
        for (let index = 0; index < data.groups.length; index += 1) {
          if (data.groups[index].id === workspaceId) known = true;
        }
        if (!known) workspaceId = '';
      }
      if (workspaceId === '') {
        for (let index = 0; index < data.groups.length; index += 1) {
          if (data.groups[index].id !== '') {
            workspaceId = data.groups[index].id;
            break;
          }
        }
      }
      taskSink.startTask(workspaceId, text).then(
        function (sessionId) {
          ackTask(id, true, '');
          // the companion brings DSH forward when "open after send" is on; this
          // frame then reveals the session it just created
          if (task.open === true && typeof taskSink.openSession === 'function') {
            taskSink.openSession(sessionId);
          }
        },
        function (failure) {
          ackTask(id, false, failure && failure.code ? failure.code : 'failed');
        }
      );
    }

    /**
     * Headless helper: publishes status to the native companion (menu bar item
     * plus its floating capture window) and drains the tasks queued there. A
     * task typed while DSH was closed survives in the companion's queue and is
     * delivered here on the first poll after the page loads.
     */
    function StatusReporter(props) {
      const data = useDockData(props);
      const body = React.useMemo(
        function () {
          return JSON.stringify(buildBridgePayload(data));
        },
        [data]
      );

      React.useEffect(
        function () {
          postBridge(body);
          const timer = setInterval(function () {
            postBridge(body);
          }, BRIDGE_HEARTBEAT_MS);
          // Chromium throttles timers in hidden/minimized windows; re-send the
          // moment the page becomes visible or focused again so the menu bar
          // item never looks stale right after the user comes back.
          function resend() {
            postBridge(body);
          }
          window.addEventListener('focus', resend);
          document.addEventListener('visibilitychange', resend);
          window.addEventListener('pageshow', resend);
          return function () {
            clearInterval(timer);
            window.removeEventListener('focus', resend);
            document.removeEventListener('visibilitychange', resend);
            window.removeEventListener('pageshow', resend);
          };
        },
        [body]
      );

      React.useEffect(
        function () {
          let stopped = false;
          function poll() {
            if (stopped) return;
            try {
              if (typeof fetch !== 'function') return;
              fetch(BRIDGE_BASE + '/command', { cache: 'no-store' })
                .then(function (response) {
                  return response.ok ? response.json() : null;
                })
                .then(function (command) {
                  if (stopped || command === null || command === undefined) return;
                  const queued = Array.isArray(command.tasks) ? command.tasks : [];
                  for (let index = 0; index < queued.length; index += 1) {
                    deliverTask(queued[index], data);
                  }
                })
                .catch(function () {
                  // companion offline
                });
            } catch (error) {
              // ignore: the poll retries on the next tick
            }
          }
          const timer = setInterval(poll, BRIDGE_COMMAND_MS);
          return function () {
            stopped = true;
            clearInterval(timer);
          };
        },
        []
      );

      return null;
    }
    //#endregion

    /**
     * The one-click installer endpoint served by the Host half. Resolved against
     * the page URL so it works both inside the desktop shell (dsh-app://app/…,
     * which the shell forwards to the Harness web server) and in a browser tab.
     */
    function companionInstallUrl(suffix) {
      try {
        return new URL('/dsh-status-box/' + suffix, window.location.href).href;
      } catch (error) {
        return '';
      }
    }

    function isMacPlatform() {
      try {
        const probe = String(navigator.platform || '') + ' ' + String(navigator.userAgent || '');
        return probe.indexOf('Mac') !== -1;
      } catch (error) {
        return false;
      }
    }

    /**
     * Settings page: one switch mirrored into the companion's config.json over
     * the same loopback bridge. The native window reads it when a task is
     * submitted, so both surfaces always agree.
     */
    function SettingsSection(props) {
      const t = props.t;
      const [state, setState] = React.useState({ phase: 'loading', openOnSend: false, detail: '' });

      // Bumped to re-run the probe: automatic retries while the companion starts
      // up, plus a manual retry from the offline note below.
      const [attempt, setAttempt] = React.useState(0);

      React.useEffect(function () {
        // TEMP-PROBE-BEGIN: prove the renderer reaches the Host route
        try {
          const probe = companionInstallUrl('status?probe=client');
          if (probe && typeof fetch === 'function') fetch(probe, { cache: 'no-store' }).catch(function () {});
        } catch (error) {
          // diagnostics only
        }
        // TEMP-PROBE-END
        let stopped = false;
        let timer = 0;
        function retryLater() {
          if (stopped) return;
          // first few probes are quick (the companion may still be launching),
          // then settle on a slow heartbeat so the page self-heals without a reload
          timer = setTimeout(function () {
            setAttempt(attempt + 1);
          }, attempt < 5 ? 1200 + attempt * 800 : 5000);
        }
        function fail(reason) {
          if (stopped) return;
          setState({ phase: 'offline', openOnSend: false, detail: reason === undefined ? '' : String(reason) });
          retryLater();
        }
        try {
          if (typeof fetch !== 'function') {
            fail();
            return function () {};
          }
          fetch(BRIDGE_BASE + '/config', { cache: 'no-store' })
            .then(function (response) {
              if (!response.ok) {
                throw new Error('HTTP ' + response.status);
              }
              return response.json();
            })
            .then(function (config) {
              if (stopped) return;
              const value = config === null || config === undefined ? undefined : config.openOnSend;
              // accept both JSON booleans and 0/1 so an older companion still works
              if (typeof value === 'boolean' || (typeof value === 'number' && (value === 0 || value === 1))) {
                setState({ phase: 'ready', openOnSend: value === true || value === 1 });
              } else {
                fail('unexpected payload: ' + JSON.stringify(config));
              }
            })
            .catch(function (error) {
              fail(error && error.message ? error.message : 'network error');
            });
        } catch (error) {
          fail();
        }
        return function () {
          stopped = true;
          if (timer !== 0) clearTimeout(timer);
        };
      }, [attempt]);

      function setPreference(next) {
        setState({ phase: 'ready', openOnSend: next });
        try {
          if (typeof fetch !== 'function') return;
          fetch(BRIDGE_BASE + '/config', {
            method: 'POST',
            mode: 'cors',
            cache: 'no-store',
            headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
            body: JSON.stringify({ openOnSend: next })
          })
            .then(function (response) {
              if (!response.ok) throw new Error('config rejected');
            })
            .catch(function () {
              setState({ phase: 'offline', openOnSend: next });
            });
        } catch (error) {
          // ignore: the switch already shows the optimistic value
        }
      }

      const [install, setInstall] = React.useState({ phase: 'idle', error: '' });
      const [copied, setCopied] = React.useState(false);

      function installCompanion() {
        const url = companionInstallUrl('install');
        setInstall({ phase: 'busy', error: '' });
        if (!url || typeof fetch !== 'function') {
          setInstall({ phase: 'error', error: 'no endpoint' });
          return;
        }
        fetch(url, {
          method: 'POST',
          cache: 'no-store',
          headers: { 'Content-Type': 'text/plain;charset=UTF-8', 'X-Dsh-Status-Box': 'install' },
          body: ''
        })
          .then(function (response) {
            return response.json().catch(function () {
              return { ok: false, error: 'HTTP ' + response.status };
            });
          })
          .then(function (result) {
            if (result && result.ok === true) {
              setInstall({ phase: 'done', error: '' });
              setAttempt(attempt + 1);
            } else {
              setInstall({ phase: 'error', error: String((result && result.error) || 'unknown') });
            }
          })
          .catch(function (error) {
            setInstall({ phase: 'error', error: error && error.message ? error.message : 'network error' });
          });
      }

      function copyInstallCommand() {
        try {
          const command = 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/Nuke0519/dsh-status-box/main/menubar/install-prebuilt.sh)"';
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(command);
            setCopied(true);
            setTimeout(function () { setCopied(false); }, 2000);
          }
        } catch (error) {
          // clipboard unavailable: the button simply does nothing visible
        }
      }

      const ready = state.phase !== 'offline';
      return h(
        'div',
        { className: 'qd-settings' },
        h('h2', { className: 'qd-settings-title' }, t('settings.title')),
        h('p', { className: 'qd-settings-desc' }, t('settings.desc')),
        h(
          'div',
          { className: 'qd-settings-row' },
          h(
            'div',
            { className: 'qd-settings-label' },
            h('span', null, t('settings.openOnSend')),
            h('p', { className: 'qd-settings-hint' }, t('settings.openOnSendHint'))
          ),
          h(
            'button',
            {
              type: 'button',
              role: 'switch',
              'aria-checked': state.openOnSend ? 'true' : 'false',
              'aria-label': t('settings.openOnSend'),
              className: 'qd-switch' + (state.openOnSend ? ' on' : ''),
              disabled: !ready,
              onClick: function () {
                setPreference(!state.openOnSend);
              }
            },
            h('span', { className: 'qd-switch-knob' })
          )
        ),
        ready
          ? null
          : h(
              'div',
              null,
              h(
                'p',
                { className: 'qd-settings-note' },
                t('settings.offline'),
                state.detail ? h('span', { className: 'qd-settings-detail' }, '（' + state.detail + '）') : null,
                ' ',
                h(
                  'button',
                  {
                    type: 'button',
                    className: 'qd-retry',
                    onClick: function () {
                      setState({ phase: 'loading', openOnSend: state.openOnSend });
                      setAttempt(attempt + 1);
                    }
                  },
                  t('settings.retry')
                )
              ),
              isMacPlatform()
                ? h(
                    'div',
                    { className: 'qd-settings-install' },
                    h(
                      'button',
                      {
                        type: 'button',
                        className: 'qd-install',
                        disabled: install.phase === 'busy' || install.phase === 'done',
                        onClick: installCompanion
                      },
                      install.phase === 'busy'
                        ? t('settings.installing')
                        : install.phase === 'done'
                          ? t('settings.installed')
                          : t('settings.install')
                    ),
                    install.phase === 'error'
                      ? h(
                          'p',
                          { className: 'qd-settings-note' },
                          t('settings.installFailed', { reason: install.error })
                        )
                      : null,
                    install.phase === 'error'
                      ? h(
                          'button',
                          { type: 'button', className: 'qd-retry', onClick: copyInstallCommand },
                          copied ? t('settings.copied') : t('settings.copyCommand')
                        )
                      : null
                  )
                : h('p', { className: 'qd-settings-note' }, t('settings.notMac'))
            )
      );
    }

    function wrapFailure(cause) {
      const failure = new Error(
        cause !== undefined && cause !== null && cause.message !== undefined ? String(cause.message) : String(cause)
      );
      failure.code = 'failed';
      return failure;
    }


    return {
      inject: ['slots', 'locale'],
      // Pure helpers, used by /tmp style node:test coverage; the module loader
      // only ever reads inject/apply, so this stays inert at runtime.
      __internal: { aggregate, buildBridgePayload, stateOf, toRow, visibleSession },
      apply(ctx) {
        ctx.effect(function () {
          return ctx.locale.register(NS, { zh, en });
        }, NS + ': dictionaries');
        ctx.effect(function () {
          return insertStyles(CSS, NS);
        }, NS + ': styles');

        /**
         * The capture UI is a native macOS window owned by the menu-bar
         * companion, so the plugin only has to poke it. POST /nudge toggles
         * that window — the same thing the global hotkey does.
         */
        function summonNative() {
          try {
            if (typeof fetch !== 'function') return;
            fetch(BRIDGE_BASE + '/nudge', { cache: 'no-store' }).catch(function () {});
          } catch (error) {
            // companion offline: the hotkey still works when it is back
          }
        }

        function startTask(workspaceId, text) {
          return new Promise(function (resolve, reject) {
            const value = String(text === undefined || text === null ? '' : text).trim();
            if (value === '') {
              const empty = new Error('empty prompt');
              empty.code = 'empty';
              reject(empty);
              return;
            }
            const uiWorkspace = ctx.get('uiWorkspace');
            const sessions = ctx.get('sessions');
            if (
              uiWorkspace === undefined ||
              uiWorkspace === null ||
              typeof uiWorkspace.connectWorkspace !== 'function' ||
              sessions === undefined ||
              sessions === null ||
              typeof sessions.using !== 'function'
            ) {
              const missing = new Error('quick capture services unavailable');
              missing.code = 'noService';
              reject(missing);
              return;
            }
            let opened;
            try {
              opened = uiWorkspace.connectWorkspace(workspaceId);
            } catch (cause) {
              reject(wrapFailure(cause));
              return;
            }
            Promise.resolve(opened).then(function (sessionId) {
              if (sessionId === undefined || sessionId === null || sessionId === '') {
                reject(wrapFailure(new Error('connectWorkspace returned no session id')));
                return;
              }
              return sessions
                .using(sessionId, { source: 'controllerOperation' }, function (reference) {
                  return Promise.resolve(reference.ready).then(function (binding) {
                    return binding.session.prompt([{ type: 'text', text: value }], 'queue').then(function (result) {
                      if (result === undefined || result === null || result.ok !== true) {
                        const failure = new Error(
                          result !== undefined && result !== null && result.error !== undefined && result.error !== null
                            ? String(result.error.message !== undefined ? result.error.message : result.error.code)
                            : 'prompt rejected by the session'
                        );
                        failure.code = 'failed';
                        throw failure;
                      }
                      return sessionId;
                    });
                  });
                })
                .then(
                  function () {
                    resolve(sessionId);
                  },
                  function (cause) {
                    reject(wrapFailure(cause));
                  }
                );
            }, function (cause) {
              reject(wrapFailure(cause));
            });
          });
        }

        const desk = {
          summonNative,
          startTask
        };

        taskSink.startTask = startTask;
        taskSink.openSession = function (sessionId) {
          const uiWorkspace = ctx.get('uiWorkspace');
          if (uiWorkspace === undefined || uiWorkspace === null) return;
          if (typeof uiWorkspace.openSession !== 'function') return;
          try {
            uiWorkspace.openSession(sessionId);
          } catch (error) {
            // navigation is cosmetic here: the task has already started
          }
        };
        const boundOpenSession = taskSink.openSession;
        ctx.effect(function () {
          return function () {
            if (taskSink.startTask === startTask) taskSink.startTask = null;
            if (taskSink.openSession === boundOpenSession) taskSink.openSession = null;
          };
        }, NS + ': bridge sink');

        ctx.effect(function () {
          function onKeyDown(event) {
            if (event.defaultPrevented === true) return;
            const key = event.key;
            const modified = event.metaKey === true || event.ctrlKey === true;
            if (modified && event.shiftKey === true && key !== undefined && key.toLowerCase() === HOTKEY_KEY) {
              event.preventDefault();
              event.stopPropagation();
              summonNative();
            }
          }
          window.addEventListener('keydown', onKeyDown, true);
          return function () {
            window.removeEventListener('keydown', onKeyDown, true);
          };
        }, NS + ': shortcuts');

        ctx.slots.inject('conversation.header.leading', function () {
          return ctx.slots.register(
            { name: 'conversation.header.leading', locale: NS, inject: () => ({ desk }) },
            StatusPill
          );
        });
        const t = ctx.locale.bind(NS);
        ctx.slots.inject('settings.section', function () {
          return ctx.slots.register(
            {
              name: 'settings.section',
              id: NS,
              order: 35,
              label: function () {
                return t('settings.title');
              },
              locale: NS,
              inject: () => ({ desk })
            },
            SettingsSection
          );
        });
        ctx.slots.inject('shell.overlay', function () {
          return ctx.slots.register(
            {
              name: 'shell.overlay',
              id: NS + '.bridge',
              order: 61,
              label: () => NS + ': bridge',
              locale: NS,
              inject: () => ({ desk })
            },
            StatusReporter
          );
        });
      }
    };
  }
});
