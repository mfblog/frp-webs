<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'

type Tab = 'config' | 'status' | 'logs'
type Tone = 'info' | 'success' | 'warning' | 'danger'

interface ApiEnvelope<T> { ok: boolean; data?: T; message?: string }
interface SessionData { authenticated: boolean; required: boolean }
interface DiscoveryInfo { binary?: string; config?: string; source?: string }
interface StatusData {
  service: string
  active: string
  enabled: string
  version: string
  config_exists: boolean
  config_mtime: number | null
  discovery?: DiscoveryInfo
}
interface ConfigData { content: string; exists: boolean; revision: string | null }

const activeTab = ref<Tab>('config')
const authenticated = ref(false)
const authRequired = ref(false)
const token = ref('')
const authError = ref('')
const authBusy = ref(false)

const status = ref<StatusData>({
  service: 'frpc.service', active: 'unknown', enabled: 'unknown', version: 'unknown',
  config_exists: false, config_mtime: null,
})
const config = ref('')
const savedConfig = ref('')
const editVersion = ref(0)
const revision = ref<string | null>(null)
const configExists = ref(false)
const busy = ref<string | null>(null)
const message = ref('正在连接 frpc Web 控制台…')
const messageTone = ref<Tone>('info')

const logs = ref('')
const logsBusy = ref(false)
const logsError = ref('')
const autoFollow = ref(true)
const logElement = ref<HTMLElement | null>(null)
let logTimer: number | undefined

class ApiError<T = unknown> extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly envelope: ApiEnvelope<T>,
  ) {
    super(message)
  }
}

const dirty = computed(() => config.value !== savedConfig.value)
const isActive = computed(() => status.value.active === 'active')
const primaryAction = computed(() => isActive.value ? '保存并重启' : '保存并启动')
const discoveredBin = computed(() => status.value.discovery?.binary || '尚未发现')
const discoveredConfig = computed(() => status.value.discovery?.config || '/usr/local/frpc/frpc.toml')

async function api<T>(path: string, init: RequestInit = {}): Promise<ApiEnvelope<T>> {
  const headers = new Headers(init.headers)
  if (init.body) headers.set('Content-Type', 'application/json')
  const response = await fetch(path, { ...init, headers, credentials: 'same-origin' })
  let payload: ApiEnvelope<T>
  try {
    payload = await response.json() as ApiEnvelope<T>
  } catch {
    throw new Error(`服务器返回了无法识别的响应（HTTP ${response.status}）`)
  }
  if (response.status === 401 && path !== '/api/session') authenticated.value = false
  if (!response.ok || !payload.ok) throw new ApiError(payload.message || `请求失败（HTTP ${response.status}）`, response.status, payload)
  return payload
}

function notify(text: string, tone: Tone = 'info') {
  message.value = text
  messageTone.value = tone
}

async function checkSession() {
  try {
    const result = await api<SessionData>('/api/session')
    authenticated.value = result.data?.authenticated === true
    authRequired.value = result.data?.required === true
  } catch {
    authenticated.value = false
    authRequired.value = true
  }
  if (authenticated.value || !authRequired.value) await bootConsole()
}

async function login() {
  authBusy.value = true
  authError.value = ''
  try {
    const result = await api<SessionData>('/api/session', { method: 'POST', body: JSON.stringify({ token: token.value }) })
    authenticated.value = result.data?.authenticated === true
    token.value = ''
    await bootConsole()
  } catch (error) {
    authError.value = error instanceof Error ? error.message : '登录失败'
  } finally {
    authBusy.value = false
  }
}

async function refreshStatus(silent = false) {
  try {
    const result = await api<StatusData>('/api/status')
    if (result.data) status.value = result.data
    if (!silent) notify('运行状态已刷新。', 'success')
  } catch (error) {
    if (!silent) notify(error instanceof Error ? error.message : '读取状态失败', 'danger')
  }
}

async function loadConfig(force = false) {
  if (dirty.value && !force && !window.confirm('当前有未保存修改，确认用磁盘内容覆盖吗？')) return
  const requestEditVersion = editVersion.value
  busy.value = 'load'
  try {
    const result = await api<ConfigData>('/api/config')
    const data = result.data
    if (!data) throw new Error('配置响应缺少 data')
    if (editVersion.value !== requestEditVersion) {
      notify('读取期间检测到新的编辑内容，已保留当前输入。需要时请再次点击“重新读取”。', 'warning')
      return
    }
    config.value = data.content || ''
    savedConfig.value = config.value
    revision.value = data.revision
    configExists.value = data.exists
    notify(data.exists ? '配置已从磁盘读取。' : '尚未创建 frpc.toml，请完成首次配置。', data.exists ? 'success' : 'info')
  } catch (error) {
    notify(error instanceof Error ? error.message : '读取配置失败', 'danger')
  } finally {
    busy.value = null
  }
}

async function verifyConfig() {
  busy.value = 'verify'
  try {
    const result = await api<never>('/api/verify', { method: 'POST', body: JSON.stringify({ content: config.value }) })
    notify(result.message || '配置校验通过。', 'success')
  } catch (error) {
    notify(error instanceof Error ? error.message : '配置校验失败', 'danger')
  } finally {
    busy.value = null
  }
}

async function saveConfig(restart: boolean) {
  const submittedContent = config.value
  const submittedRevision = revision.value
  busy.value = restart ? 'save-restart' : 'save'
  try {
    const result = await api<{ revision: string; exists: boolean }>('/api/config', {
      method: 'POST',
      body: JSON.stringify({ content: submittedContent, restart, revision: submittedRevision }),
    })
    savedConfig.value = submittedContent
    revision.value = result.data?.revision || null
    configExists.value = result.data?.exists === true
    notify(
      config.value === submittedContent
        ? (result.message || (restart ? `${primaryAction.value}成功。` : '配置已保存。'))
        : '提交时的配置已保存；你在保存期间继续编辑的内容仍未保存。',
      config.value === submittedContent ? 'success' : 'warning',
    )
    await refreshStatus(true)
    if (restart) await refreshLogs(false)
  } catch (error) {
    if (error instanceof ApiError) {
      const data = error.envelope.data as { revision?: string | null; exists?: boolean } | undefined
      if (data && 'revision' in data) revision.value = data.revision || null
      if (data && typeof data.exists === 'boolean') configExists.value = data.exists
    }
    const text = error instanceof Error ? error.message : '保存配置失败'
    notify(text, text.includes('修改') || text.includes('冲突') ? 'warning' : 'danger')
  } finally {
    busy.value = null
  }
}

async function serviceAction(action: 'start' | 'stop' | 'restart') {
  const labels = { start: '启动', stop: '停止', restart: '重启' }
  if (action === 'stop' && !window.confirm('确认停止 frpc 服务吗？现有代理连接会中断。')) return
  busy.value = action
  try {
    const result = await api<never>('/api/service', { method: 'POST', body: JSON.stringify({ action }) })
    notify(result.message || `frpc ${labels[action]}成功。`, 'success')
    await refreshStatus(true)
    await refreshLogs(false)
  } catch (error) {
    notify(error instanceof Error ? error.message : `frpc ${labels[action]}失败`, 'danger')
  } finally {
    busy.value = null
  }
}

function nearLogBottom(element: HTMLElement) {
  return element.scrollHeight - element.scrollTop - element.clientHeight < 48
}

function handleLogScroll() {
  if (logElement.value) autoFollow.value = nearLogBottom(logElement.value)
}

async function scrollLogsToBottom() {
  await nextTick()
  if (logElement.value) logElement.value.scrollTop = logElement.value.scrollHeight
}

async function refreshLogs(showFeedback = true) {
  if (logsBusy.value) return
  const shouldFollow = autoFollow.value
  logsBusy.value = true
  logsError.value = ''
  try {
    const result = await api<{ logs: string }>('/api/logs?lines=300')
    logs.value = result.data?.logs || ''
    if (shouldFollow) await scrollLogsToBottom()
    if (showFeedback) notify(logs.value ? '日志已刷新。' : '服务当前没有可显示的日志。', 'success')
  } catch (error) {
    logsError.value = error instanceof Error ? error.message : '日志读取失败'
    if (showFeedback) notify(logsError.value, 'danger')
  } finally {
    logsBusy.value = false
  }
}

function jumpToLatest() {
  autoFollow.value = true
  void scrollLogsToBottom()
}

async function bootConsole() {
  await Promise.all([refreshStatus(true), loadConfig(true), refreshLogs(false)])
  if (logTimer) window.clearInterval(logTimer)
  logTimer = window.setInterval(() => void refreshLogs(false), 5000)
}

function formatTime(timestamp: number | null) {
  if (!timestamp) return '尚无配置'
  return new Date(timestamp * 1000).toLocaleString('zh-CN', { hour12: false })
}

function keySave(event: KeyboardEvent) {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
    event.preventDefault()
    if (dirty.value && !busy.value) void saveConfig(false)
  }
}

onMounted(() => {
  window.addEventListener('keydown', keySave)
  window.addEventListener('beforeunload', preventDirtyUnload)
  void checkSession()
})

function preventDirtyUnload(event: BeforeUnloadEvent) {
  if (!dirty.value) return
  event.preventDefault()
  event.returnValue = ''
}

onBeforeUnmount(() => {
  window.removeEventListener('keydown', keySave)
  window.removeEventListener('beforeunload', preventDirtyUnload)
  if (logTimer) window.clearInterval(logTimer)
})
</script>

<template>
  <main v-if="!authenticated && authRequired" class="min-h-dvh grid place-items-center p-5">
    <form class="panel w-full max-w-md p-6 sm:p-8" @submit.prevent="login">
      <div class="mb-7 flex items-center gap-3">
        <div class="grid size-10 place-items-center rounded-xl bg-blue-600 text-sm font-black text-white">FRP</div>
        <div>
          <h1 class="m-0 text-xl font-bold tracking-tight">frpc 控制台</h1>
          <p class="mt-1 text-sm text-slate-600">输入安装时生成的访问令牌</p>
        </div>
      </div>
      <label for="token" class="mb-2 block text-sm font-semibold">访问令牌</label>
      <input id="token" v-model="token" type="password" autocomplete="current-password" autofocus required
        class="w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 placeholder:text-slate-500" placeholder="请输入访问令牌" />
      <p v-if="authError" role="alert" class="mt-3 text-sm font-medium text-red-700">{{ authError }}</p>
      <button type="submit" :disabled="authBusy" class="mt-5 w-full rounded-lg bg-blue-600 px-4 py-2.5 text-sm font-bold text-white hover:bg-blue-700 disabled:opacity-60">
        {{ authBusy ? '正在验证…' : '进入控制台' }}
      </button>
    </form>
  </main>

  <div v-else class="app-shell">
    <header class="border-b border-slate-200 bg-white">
      <div class="mx-auto flex w-full max-w-[1480px] flex-wrap items-center justify-between gap-3 px-4 py-3 sm:px-5">
        <div class="flex min-w-0 items-center gap-3">
          <div class="grid size-9 shrink-0 place-items-center rounded-lg bg-blue-600 text-xs font-black text-white">FRP</div>
          <div class="min-w-0">
            <h1 class="truncate text-base font-bold tracking-tight text-slate-900">frpc 控制台</h1>
            <p class="truncate text-xs text-slate-600">{{ discoveredBin }}</p>
          </div>
        </div>
        <div class="flex items-center gap-2 text-xs font-semibold">
          <span class="rounded-full border px-2.5 py-1" :class="isActive ? 'border-emerald-200 bg-emerald-50 text-emerald-800' : 'border-slate-300 bg-slate-100 text-slate-700'">
            {{ isActive ? '运行中' : status.active }}
          </span>
          <span class="hidden rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 text-slate-700 sm:inline">v{{ status.version }}</span>
          <button class="rounded-lg border border-slate-300 bg-white px-3 py-1.5 hover:bg-slate-50" :disabled="busy !== null" @click="refreshStatus()">刷新状态</button>
        </div>
      </div>
    </header>

    <div class="workspace">
      <nav class="mobile-tabs overflow-hidden rounded-xl border border-slate-200 bg-white p-1" aria-label="移动端页面区域">
        <button v-for="tab in ([['config','配置'],['status','状态'],['logs','日志']] as const)" :key="tab[0]" type="button"
          class="rounded-lg px-2 py-2 text-sm font-semibold" :class="activeTab === tab[0] ? 'bg-blue-600 text-white' : 'text-slate-700'" @click="activeTab = tab[0]">{{ tab[1] }}</button>
      </nav>

      <section class="panel editor-panel" :class="{ 'mobile-active': activeTab === 'config' }">
        <div class="flex flex-wrap items-start justify-between gap-3 border-b border-slate-200 px-4 py-4 sm:px-5">
          <div>
            <div class="flex items-center gap-2">
              <h2 class="text-base font-bold text-slate-900">frpc.toml</h2>
              <span class="rounded-full px-2 py-0.5 text-xs font-semibold" :class="dirty ? 'bg-amber-100 text-amber-800' : 'bg-slate-100 text-slate-700'">{{ dirty ? '未保存' : (configExists ? '已保存' : '尚未配置') }}</span>
            </div>
            <p class="mt-1 max-w-[70ch] break-all text-xs text-slate-600">{{ discoveredConfig }}</p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button class="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-semibold hover:bg-slate-50 disabled:opacity-50" :disabled="busy !== null" @click="loadConfig()">重新读取</button>
            <button class="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-semibold hover:bg-slate-50 disabled:opacity-50" :disabled="busy !== null || !config.trim()" @click="verifyConfig">{{ busy === 'verify' ? '校验中…' : '校验配置' }}</button>
          </div>
        </div>
        <textarea v-model="config" aria-label="frpc.toml 配置内容" spellcheck="false" @input="editVersion++"
          class="mono min-h-[480px] w-full flex-1 resize-y border-0 bg-slate-950 p-4 text-[13px] leading-6 text-slate-100 outline-none sm:p-5"
          placeholder="# 在这里填写完整的 frpc.toml"></textarea>
        <div class="flex flex-col gap-3 border-t border-slate-200 px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-5">
          <p class="text-xs text-slate-600">支持 Ctrl/Cmd + S 保存。启动前会先执行 frpc 配置校验。</p>
          <div class="flex flex-col gap-2 sm:flex-row">
            <button class="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-bold hover:bg-slate-50 disabled:opacity-50" :disabled="busy !== null || !dirty" @click="saveConfig(false)">{{ busy === 'save' ? '保存中…' : '仅保存' }}</button>
            <button class="rounded-lg bg-blue-600 px-4 py-2 text-sm font-bold text-white hover:bg-blue-700 disabled:opacity-50" :disabled="busy !== null || (!dirty && isActive) || !config.trim()" @click="saveConfig(true)">{{ busy === 'save-restart' ? '处理中…' : primaryAction }}</button>
          </div>
        </div>
      </section>

      <aside class="panel side-panel" :class="{ 'mobile-active': activeTab === 'status' }">
        <div class="border-b border-slate-200 px-4 py-4 sm:px-5">
          <h2 class="text-base font-bold text-slate-900">服务状态</h2>
          <p class="mt-1 text-xs text-slate-600">由 systemd 管理 {{ status.service }}</p>
        </div>
        <dl class="grid grid-cols-2 gap-px bg-slate-200">
          <div class="bg-white p-4"><dt class="text-xs font-semibold text-slate-600">运行状态</dt><dd class="mt-1 text-lg font-bold text-slate-900">{{ status.active }}</dd></div>
          <div class="bg-white p-4"><dt class="text-xs font-semibold text-slate-600">开机自启</dt><dd class="mt-1 text-lg font-bold text-slate-900">{{ status.enabled }}</dd></div>
          <div class="bg-white p-4"><dt class="text-xs font-semibold text-slate-600">frpc 版本</dt><dd class="mt-1 text-lg font-bold text-slate-900">{{ status.version }}</dd></div>
          <div class="bg-white p-4"><dt class="text-xs font-semibold text-slate-600">配置更新时间</dt><dd class="mt-1 text-sm font-bold leading-6 text-slate-900">{{ formatTime(status.config_mtime) }}</dd></div>
        </dl>
        <div class="p-4 sm:p-5">
          <h3 class="text-sm font-bold text-slate-900">服务操作</h3>
          <p class="mt-1 text-xs leading-5 text-slate-600">启动和重启需要磁盘中存在有效配置。</p>
          <div class="mt-4 grid grid-cols-2 gap-2">
            <button class="rounded-lg bg-blue-600 px-3 py-2.5 text-sm font-bold text-white hover:bg-blue-700 disabled:opacity-50" :disabled="busy !== null || !configExists" @click="serviceAction('start')">启动</button>
            <button class="rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm font-bold hover:bg-slate-50 disabled:opacity-50" :disabled="busy !== null || !configExists" @click="serviceAction('restart')">重启</button>
            <button class="col-span-2 rounded-lg border border-red-300 bg-red-50 px-3 py-2.5 text-sm font-bold text-red-800 hover:bg-red-100 disabled:opacity-50" :disabled="busy !== null || !isActive" @click="serviceAction('stop')">停止服务</button>
          </div>
        </div>
      </aside>

      <section class="panel logs-panel" :class="{ 'mobile-active': activeTab === 'logs' }">
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 px-4 py-3 sm:px-5">
          <div>
            <h2 class="text-base font-bold text-slate-900">运行日志</h2>
            <p class="mt-0.5 text-xs text-slate-600">最近 300 行 · 每 5 秒刷新</p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <label class="flex items-center gap-2 text-xs font-semibold text-slate-700">
              <input v-model="autoFollow" type="checkbox" class="size-4 accent-blue-600" @change="autoFollow && jumpToLatest()" />自动跟随
            </label>
            <button v-if="!autoFollow" class="rounded-lg border border-blue-300 bg-blue-50 px-3 py-1.5 text-xs font-bold text-blue-800" @click="jumpToLatest">跳到最新</button>
            <button class="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs font-bold hover:bg-slate-50 disabled:opacity-50" :disabled="logsBusy" @click="refreshLogs()">{{ logsBusy ? '刷新中…' : '刷新日志' }}</button>
          </div>
        </div>
        <div ref="logElement" tabindex="0" aria-label="frpc 服务日志，可上下滚动" class="log-scroll mono bg-slate-950 p-4 text-[12px] leading-5 text-slate-200 sm:p-5" @scroll.passive="handleLogScroll">
          <p v-if="logsError" role="alert" class="m-0 whitespace-pre-wrap text-red-300">{{ logsError }}</p>
          <p v-else-if="logsBusy && !logs" class="m-0 text-slate-400">正在读取日志…</p>
          <p v-else-if="!logs" class="m-0 text-slate-400">当前没有可显示的日志。启动 frpc 后，新日志会出现在这里。</p>
          <pre v-else class="m-0 whitespace-pre-wrap break-words font-inherit">{{ logs }}</pre>
        </div>
      </section>
    </div>

    <div class="fixed bottom-4 left-1/2 z-50 w-[min(680px,calc(100%-24px))] -translate-x-1/2 rounded-xl border px-4 py-3 text-sm font-semibold shadow-lg"
      :class="{
        'border-blue-200 bg-blue-50 text-blue-900': messageTone === 'info',
        'border-emerald-200 bg-emerald-50 text-emerald-900': messageTone === 'success',
        'border-amber-200 bg-amber-50 text-amber-900': messageTone === 'warning',
        'border-red-200 bg-red-50 text-red-900': messageTone === 'danger',
      }" role="status" aria-live="polite">{{ message }}</div>
  </div>
</template>
