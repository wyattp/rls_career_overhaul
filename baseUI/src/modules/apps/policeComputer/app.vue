<template>
  <div class="police-computer bng-app" v-show="isVisible" :class="{ collapsed: isCollapsed }">
    <!-- Header - always visible -->
    <div class="pc-header">
      <div class="pc-title">
        <span class="pc-badge">ANPR</span>
        <span class="pc-label">Police Computer</span>
        <span class="cone-indicators" v-if="anprActive">
          <span class="cone-icon cone-left" :class="{ active: coneLeftHit }" title="Left ANPR">&#8592;</span>
          <span class="cone-icon cone-front" :class="{ active: coneFrontHit }" title="Front ANPR">&#8593;</span>
        </span>
      </div>
      <div class="pc-controls">
        <button
          class="anpr-toggle"
          :class="{ active: anprActive }"
          @click.stop="toggleANPR">
          {{ anprActive ? 'ON' : 'OFF' }}
        </button>
        <button class="minimize-btn" @click.stop="toggleCollapse" :title="isCollapsed ? 'Expand' : 'Minimize'">
          {{ isCollapsed ? '&#9660;' : '&#9650;' }}
        </button>
      </div>
    </div>

    <!-- Action banner (fleeing/stopping/rabbit) -->
    <div class="action-banner" v-if="actionBanner" :class="'action-' + actionBanner.type">
      {{ actionBanner.text }}
    </div>

    <!-- Stop progress bar -->
    <div class="stop-progress" v-if="stopProgress">
      <div class="stop-progress-bar" :style="{ width: (stopProgress.timer / stopProgress.total * 100) + '%' }"></div>
      <span class="stop-progress-label">TARGETING {{ stopProgress.plate || '...' }}</span>
    </div>

    <!-- Body - collapsible -->
    <div class="pc-body" v-if="!isCollapsed">
      <!-- Scanned plates list -->
      <div class="plates-list" v-if="scannedPlates.length > 0">
        <div
          class="plate-row"
          v-for="entry in scannedPlates"
          :key="entry.vehId || entry.plate"
          :class="{ flagged: entry.flagged, selected: selectedVehId === entry.vehId, ahead: aheadPlate === entry.plate }"
          @click="selectPlate(entry)">
          <span class="plate-number">{{ entry.plate }}</span>
          <span class="plate-vehicle">{{ entry.vehicleName }}</span>
          <span class="plate-status" :class="entry.flagged ? 'status-alert' : 'status-clear'">
            {{ entry.flagged ? '!' : '&#10003;' }}
          </span>
        </div>
      </div>
      <div class="plates-empty" v-else>
        <span v-if="anprActive">Scanning...</span>
        <span v-else>ANPR inactive</span>
      </div>

      <!-- Detail panel -->
      <div class="detail-panel" v-if="selectedRecord" :class="{ 'detail-flagged': selectedRecord.flagged }">
        <div class="detail-close" @click.stop="selectedVehId = null; selectedRecord = null">&times;</div>
        <!-- Alerts banner -->
        <div class="alerts-banner" v-if="selectedRecord.alerts && selectedRecord.alerts.length > 0">
          <div class="alert-item" v-for="alert in selectedRecord.alerts" :key="alert">
            {{ alert }}
          </div>
        </div>

        <div class="detail-section">
          <div class="detail-heading">Vehicle</div>
          <div class="detail-row">
            <span class="detail-label">Plate:</span>
            <span class="detail-value">{{ selectedRecord.plate }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Vehicle:</span>
            <span class="detail-value">{{ selectedRecord.vehicleName }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Registered to:</span>
            <span class="detail-value">{{ selectedRecord.ownerName }}</span>
          </div>
        </div>

        <div class="detail-section">
          <div class="detail-heading">Driver</div>
          <div class="detail-row">
            <span class="detail-label">Name:</span>
            <span class="detail-value">{{ selectedRecord.driverName }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Address:</span>
            <span class="detail-value">{{ selectedRecord.address }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">License:</span>
            <span class="detail-value" :class="{ 'value-alert': selectedRecord.suspendedLicense }">
              {{ selectedRecord.suspendedLicense ? 'SUSPENDED' : 'Valid' }}
            </span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Insurance:</span>
            <span class="detail-value" :class="{ 'value-alert': selectedRecord.noInsurance }">
              {{ selectedRecord.noInsurance ? 'NONE' : 'Active' }}
            </span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Registration:</span>
            <span class="detail-value" :class="{ 'value-alert': selectedRecord.expiredRegistration }">
              {{ selectedRecord.expiredRegistration ? 'EXPIRED' : 'Current' }}
            </span>
          </div>
        </div>

        <div class="detail-section" v-if="selectedRecord.apb">
          <div class="apb-banner">APB: {{ selectedRecord.apbReason || 'Unknown' }}</div>
        </div>

        <div class="detail-section" v-if="selectedRecord.priors && selectedRecord.priors.length > 0">
          <div class="detail-heading">Prior Offenses</div>
          <div class="prior-row" v-for="(prior, idx) in selectedRecord.priors" :key="idx">
            <span class="prior-year">{{ prior.year }}</span>
            <span class="prior-offense">{{ prior.offense }}</span>
            <span class="prior-severity" :class="'severity-' + prior.severity">{{ prior.severity }}</span>
          </div>
        </div>

        <div class="detail-section" v-if="selectedRecord.wanted">
          <div class="wanted-banner">WANTED - ACTIVE WARRANT</div>
        </div>
        <div class="detail-section" v-if="selectedRecord.stolen">
          <div class="stolen-banner">REPORTED STOLEN</div>
        </div>
      </div>
    </div>
  </div>

  <div
    class="stop-action-overlay"
    v-if="stopActionMenu.open"
    v-bng-blur
    bng-ui-scope="policeStopActionMenu"
    v-bng-on-ui-nav:focus_lr,focus_ud="processStopActionStickInput"
    v-bng-on-ui-nav:focus_l,focus_r,focus_u,focus_d.down="processStopActionDpadInput"
    v-bng-on-ui-nav:focus_l,focus_r,focus_u,focus_d.up="processStopActionDpadInput"
    v-bng-on-ui-nav:ok,context="processStopActionMouseClick"
    v-bng-on-ui-nav:menu,back="processStopActionCancelInput"
    v-bng-ui-nav-label:focus_lr,focus_ud,focus_l,focus_r,focus_u,focus_d="'Radial menu navigation'"
    v-bng-ui-nav-label:ok="'Select'"
    v-bng-ui-nav-label:menu,back="'Close'"
    @contextmenu.prevent
  >
    <div class="stop-action-menu">
      <div class="stop-action-infos">
        <div class="stop-action-title">
          <span class="stop-action-title-accent"></span>
          <span>Police Stop Menu</span>
        </div>
      </div>
      <div ref="stopActionRadialCont" class="stop-action-radial"></div>
    </div>
  </div>
</template>

<script setup>
import { ref, reactive, onMounted, onUnmounted, nextTick, watch } from 'vue'
import { useLibStore } from '@/services'
import { vBngBlur, vBngOnUiNav, vBngUiNavLabel } from '@/common/directives'
import { getUINavServiceInstance } from '@/services/uiNav'
import RadialSVG from '@/modules/radial/radialsvg'

const { $game } = useLibStore()

const isVisible = ref(false)
const isCollapsed = ref(false)
const anprActive = ref(false)
const scannedPlates = ref([])
const selectedVehId = ref(null)
const selectedRecord = ref(null)
const actionBanner = ref(null)
const stopProgress = ref(null)
const aheadPlate = ref(null)
const coneFrontHit = ref(false)
const coneLeftHit = ref(false)
const stopActionMenu = reactive({
  open: false,
  targetVehId: null,
  plate: null,
  selection: null
})
const stopActionRadialCont = ref(null)
const stopActionRadialRenderer = new RadialSVG({
  down: (item) => {
    if (item && item.id) selectStopAction(item.id)
  },
  click: (item) => {
    if (item && item.id) selectStopAction(item.id)
  }
})
stopActionRadialRenderer.setMenuIcon('police')
let actionBannerTimeout = null
const STOP_ACTION_MENU_DEFAULT = 'up'
const STOP_ACTION_MENU_SCOPE = 'policeStopActionMenu'
const STOP_ACTION_STICK_THRESHOLD = 0.5
const STOP_ACTION_MENU_LABELS = {
  up: 'Arrest',
  down: 'Go Free/Warning',
  left: 'Ticket',
  right: 'Detain'
}
let stopActionPreviousScope = null
let stopActionStickX = 0
let stopActionStickY = 0
let stopActionStickActive = false
let stopActionDpadX = 0
let stopActionDpadY = 0

function normalizeStopActionSelection(selection) {
  if (selection === 'up' || selection === 'down' || selection === 'left' || selection === 'right') {
    return selection
  }
  return STOP_ACTION_MENU_DEFAULT
}

function selectStopAction(direction) {
  if (!stopActionMenu.open) return
  const action = normalizeStopActionSelection(direction)
  stopActionMenu.selection = action
  updateStopActionRadial()
  $game.api.engineLua(`if gameplay_policeComputer then gameplay_policeComputer.selectStopActionMenu("${action}") end`)
}

function buildStopActionRadialItems() {
  return [
    {
      id: 'up',
      title: 'Arrest suspect',
      icon: 'police_stop_handcuffs.svg',
      position: 0.25,
      size: 0.22,
      enabled: true,
      focused: stopActionMenu.selection === 'up'
    },
    {
      id: 'right',
      title: 'Detain / warning',
      icon: 'police_stop_warning.svg',
      position: 0.5,
      size: 0.22,
      enabled: true,
      focused: stopActionMenu.selection === 'right'
    },
    {
      id: 'down',
      title: 'Release / go free',
      icon: 'police_stop_unlock.svg',
      position: 0.75,
      size: 0.22,
      enabled: true,
      focused: stopActionMenu.selection === 'down'
    },
    {
      id: 'left',
      title: 'Issue ticket',
      icon: 'police_stop_ticket.svg',
      position: 0,
      size: 0.22,
      enabled: true,
      focused: stopActionMenu.selection === 'left'
    }
  ]
}

function updateStopActionRadial() {
  if (!stopActionMenu.open || !stopActionRadialCont.value) return
  stopActionRadialRenderer.create(stopActionRadialCont.value)
  stopActionRadialRenderer.update(buildStopActionRadialItems())
}

function clearStopActionPointerAndSelection() {
  stopActionStickX = 0
  stopActionStickY = 0
  stopActionStickActive = false
  stopActionDpadX = 0
  stopActionDpadY = 0
  stopActionMenu.selection = null
  stopActionRadialRenderer.setPointer(0, 0)
  const buttons = stopActionRadialRenderer.buttons || []
  for (const btn of buttons) {
    if (btn && typeof btn.blur === 'function') btn.blur()
  }
}

function pointToStopActionItem(x, y) {
  if (!stopActionRadialRenderer.buttons) return
  const len = stopActionRadialRenderer.buttons.length
  let idx = -1

  stopActionRadialRenderer.setPointer(x, y)

  if (x !== 0 || y !== 0) {
    const cursorPos = 0.5 - Math.atan2(y, x) / Math.PI / 2
    for (let i = 0; i < len; i++) {
      const btn = stopActionRadialRenderer.buttons[i].item
      const halfsize = btn.size / 2
      const startPos = ((btn.position - halfsize) % 1 + 1) % 1
      const endPos = ((btn.position + halfsize) % 1 + 1) % 1

      if (startPos < endPos) {
        if (cursorPos >= startPos && cursorPos < endPos) {
          idx = i
          break
        }
      } else if (cursorPos >= startPos || cursorPos < endPos) {
        idx = i
        break
      }
    }
  }

  for (let i = 0; i < len; i++) {
    if (i !== idx && typeof stopActionRadialRenderer.buttons[i].blur === 'function') {
      stopActionRadialRenderer.buttons[i].blur()
    }
  }

  if (idx > -1 && idx < len && typeof stopActionRadialRenderer.buttons[idx].focus === 'function') {
    stopActionRadialRenderer.buttons[idx].focus()
    stopActionMenu.selection = normalizeStopActionSelection(stopActionRadialRenderer.buttons[idx].item.id)
  } else {
    stopActionMenu.selection = null
  }
}

function isStopActionStickActive(x, y) {
  return Math.sqrt(x * x + y * y) > STOP_ACTION_STICK_THRESHOLD
}

function processStopActionStickInput(evt) {
  if (!stopActionMenu.open || !evt || !evt.detail) return
  if (evt.detail.name === 'focus_ud') {
    stopActionStickY = Number(evt.detail.value) || 0
  } else if (evt.detail.name === 'focus_lr') {
    stopActionStickX = Number(evt.detail.value) || 0
  } else {
    return
  }

  const stickActiveBefore = stopActionStickActive
  stopActionStickActive = isStopActionStickActive(stopActionStickX, stopActionStickY)

  if (stopActionStickActive) {
    pointToStopActionItem(stopActionStickX, stopActionStickY)
  }

  if (!stopActionStickActive && stickActiveBefore) {
    pointToStopActionItem(0, 0)
  }
}

function processStopActionDpadInput(evt) {
  if (!stopActionMenu.open || !evt || !evt.detail) return
  const value = Number(evt.detail.value) || 0
  switch (evt.detail.name) {
    case 'focus_l':
      stopActionDpadX = -value
      break
    case 'focus_r':
      stopActionDpadX = value
      break
    case 'focus_u':
      stopActionDpadY = value
      break
    case 'focus_d':
      stopActionDpadY = -value
      break
    default:
      return
  }
  stopActionDpadX = 0 + +stopActionDpadX
  stopActionDpadY = 0 + +stopActionDpadY
  pointToStopActionItem(stopActionDpadX, stopActionDpadY)
}

function processStopActionMouseClick(evt) {
  if (!stopActionMenu.open || !stopActionRadialRenderer.buttons) return
  const elm = stopActionRadialRenderer.buttons.find(btn => btn && btn._focused)
    || stopActionRadialRenderer.buttons.find(btn => btn && btn.item && btn.item.focused)
  if (elm && typeof elm.click === 'function') elm.click(evt)
}

function processStopActionCancelInput() {
  if (!stopActionMenu.open) return
  $game.api.engineLua('if gameplay_policeComputer and gameplay_policeComputer.cancelStopActionMenu then gameplay_policeComputer.cancelStopActionMenu() end')
}

watch(
  () => stopActionMenu.open,
  open => {
    const uiNav = getUINavServiceInstance()
    if (!uiNav) return

    if (open) {
      if (stopActionPreviousScope === null || stopActionPreviousScope === undefined) {
        stopActionPreviousScope = uiNav.activeScope
      }
      uiNav.setActiveScope(STOP_ACTION_MENU_SCOPE)
      clearStopActionPointerAndSelection()
      nextTick(() => updateStopActionRadial())
      return
    }

    clearStopActionPointerAndSelection()
    if (stopActionPreviousScope !== null && stopActionPreviousScope !== undefined) {
      uiNav.setActiveScope(stopActionPreviousScope)
      stopActionPreviousScope = null
    }
  }
)

function toggleCollapse() {
  isCollapsed.value = !isCollapsed.value
}

function toggleANPR() {
  $game.api.engineLua('gameplay_policeComputer.toggleANPR()')
}

function selectPlate(entry) {
  if (!entry) return
  const vehId = Number(entry.vehId)
  if (selectedVehId.value === vehId) {
    selectedVehId.value = null
    selectedRecord.value = null
    return
  }
  selectedVehId.value = vehId
  if (Number.isFinite(vehId) && vehId > 0) {
    $game.api.engineLua(`gameplay_policeComputer.lookupVehicle(${vehId})`)
    return
  }

  const plate = entry.plate || ''
  const safePlate = plate.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  $game.api.engineLua(`gameplay_policeComputer.lookupPlate("${safePlate}")`)
}

function onStateUpdate(data) {
  anprActive.value = data.anprActive
  if (data.scannedPlates) {
    scannedPlates.value = Array.isArray(data.scannedPlates) ? data.scannedPlates : Object.values(data.scannedPlates)
  }
}

function onScanResult(data) {
  if (!data || !data.record) return

  // Add to front of list, remove duplicate if exists
  const existing = scannedPlates.value.findIndex(p => p.vehId === data.record.vehId)
  if (existing >= 0) {
    scannedPlates.value.splice(existing, 1)
  }
  scannedPlates.value.unshift({
    vehId: data.record.vehId,
    plate: data.record.plate,
    vehicleName: data.record.vehicleName,
    flagged: data.record.flagged
  })

  // Trim to max
  if (scannedPlates.value.length > 4) {
    scannedPlates.value.pop()
  }
}

function onLookupResult(record) {
  if (record) {
    selectedRecord.value = record
  }
}

function showActionBanner(type, text, duration = 4000) {
  if (actionBannerTimeout) clearTimeout(actionBannerTimeout)
  actionBanner.value = { type, text }
  actionBannerTimeout = setTimeout(() => {
    actionBanner.value = null
  }, duration)
}

function onStopPrompt(data) {
  if (!data || !data.show) {
    // Clear the prompt banner
    if (actionBanner.value && actionBanner.value.isPrompt) {
      actionBanner.value = null
      if (actionBannerTimeout) clearTimeout(actionBannerTimeout)
    }
    return
  }
  const plate = data.plate || '???'
  if (actionBannerTimeout) clearTimeout(actionBannerTimeout)
  actionBanner.value = { type: 'danger', text: `INITIATE STOP ON ${plate}? [CONFIRM]`, isPrompt: true }
  // Keep showing until dismissed by Lua
}

function onAlert(data) {
  if (!data) return
  if (data.type === 'fleeing') {
    showActionBanner('danger', 'SUSPECT FLEEING' + (data.plate ? ' - ' + data.plate : ''))
  } else if (data.type === 'complying') {
    showActionBanner('info', 'VEHICLE COMPLYING' + (data.plate ? ' - ' + data.plate : ''))
  }
}

function onStopInitiated(data) {
  stopProgress.value = null
  showActionBanner('info', 'VEHICLE STOPPING' + (data && data.plate ? ' - ' + data.plate : ''))
}

function onStopProgress(data) {
  if (!data) {
    stopProgress.value = null
    return
  }
  stopProgress.value = data
}

function onRabbit(data) {
  showActionBanner('danger', 'SUSPECT FLEEING' + (data && data.plate ? ' - ' + data.plate : ''))
}

function onAhead(data) {
  aheadPlate.value = data && data.plate ? data.plate : null
  coneFrontHit.value = !!(data && data.coneFront)
  coneLeftHit.value = !!(data && data.coneLeft)
}

function onStopActionMenu(data) {
  if (!data) {
    stopActionMenu.open = false
    stopActionMenu.targetVehId = null
    stopActionMenu.plate = null
    clearStopActionPointerAndSelection()
    return
  }

  stopActionMenu.open = !!data.open
  stopActionMenu.targetVehId = Number.isFinite(Number(data.targetVehId)) ? Number(data.targetVehId) : null
  stopActionMenu.plate = data.plate || null
  if (!stopActionMenu.open) {
    clearStopActionPointerAndSelection()
    return
  }

  // Only show a highlighted option after an actual selection event.
  if (data.reason === 'navigate') {
    stopActionMenu.selection = normalizeStopActionSelection(data.selection)
  } else {
    stopActionMenu.selection = null
  }
  nextTick(() => updateStopActionRadial())
}

function onStopActionMenuConfirmed(data) {
  if (!data) return
  const selectedAction = normalizeStopActionSelection(data.action)
  const label = STOP_ACTION_MENU_LABELS[selectedAction] || 'Unknown'
  const plateSuffix = data.plate ? ` - ${data.plate}` : ''
  if (data.rewardGranted) {
    const amountSuffix = Number.isFinite(Number(data.rewardAmount)) && Number(data.rewardAmount) > 0
      ? ` ($${Number(data.rewardAmount)})`
      : ''
    showActionBanner('info', `ACTION RESOLVED - REWARD${amountSuffix}: ${label.toUpperCase()}${plateSuffix}`, 3000)
    return
  }

  showActionBanner('info', `ACTION RESOLVED - NO REWARD: ${label.toUpperCase()}${plateSuffix}`, 3000)
}

function onSelectEntry(data) {
  console.log('[ANPR] onSelectEntry fired', data)
  if (!data || data.vehId == null) {
    selectedVehId.value = null
    selectedRecord.value = null
    return
  }
  selectedVehId.value = Number(data.vehId)
  // Record comes via policeComputerLookup which fires right after
}

function onRecordExpired(data) {
  if (!data) return
  const vehId = Number(data.vehId)
  if (selectedVehId.value === vehId) {
    selectedVehId.value = null
    selectedRecord.value = null
  }
  // Remove from scanned plates list
  const idx = scannedPlates.value.findIndex(p => p.vehId === vehId)
  if (idx >= 0) scannedPlates.value.splice(idx, 1)
}

function onCycleEntry(data) {
  console.log('[ANPR] onCycleEntry fired', data, 'plates:', scannedPlates.value.length, 'selectedVehId:', selectedVehId.value)
  const plates = scannedPlates.value
  if (!plates || !plates.length) { console.log('[ANPR] no plates, returning'); return }
  const dir = (data && data.direction) || 1

  // Find current selection index
  let currentIdx = -1
  if (selectedVehId.value != null) {
    const selId = Number(selectedVehId.value)
    for (let i = 0; i < plates.length; i++) {
      if (Number(plates[i].vehId) === selId) {
        currentIdx = i
        break
      }
    }
  }

  if (currentIdx < 0) {
    // Nothing selected — select first entry
    console.log('[ANPR] nothing selected, selecting first')
    selectPlate(plates[0])
  } else {
    const nextIdx = currentIdx + dir
    if (nextIdx < 0 || nextIdx >= plates.length) {
      // Past the end — close detail panel
      console.log('[ANPR] past end, closing detail')
      selectedVehId.value = null
      selectedRecord.value = null
    } else {
      console.log('[ANPR] cycling from', currentIdx, 'to', nextIdx)
      selectPlate(plates[nextIdx])
    }
  }
}

function onVisibilityChange(data) {
  isVisible.value = data.visible
  if (!data.visible) {
    // Reset state when hiding
    selectedVehId.value = null
    selectedRecord.value = null
  }
}

onMounted(() => {
  $game.events.on('policeComputerState', onStateUpdate)
  $game.events.on('policeComputerScan', onScanResult)
  $game.events.on('policeComputerLookup', onLookupResult)
  $game.events.on('policeComputerVisibility', onVisibilityChange)
  $game.events.on('policeComputerAlert', onAlert)
  $game.events.on('policeComputerStopInitiated', onStopInitiated)
  $game.events.on('policeComputerStopProgress', onStopProgress)
  $game.events.on('policeComputerRabbit', onRabbit)
  $game.events.on('policeComputerAhead', onAhead)
  $game.events.on('policeComputerStopPrompt', onStopPrompt)
  $game.events.on('policeComputerStopActionMenu', onStopActionMenu)
  $game.events.on('policeComputerStopActionMenuConfirmed', onStopActionMenuConfirmed)
  $game.events.on('policeComputerCycleEntry', onCycleEntry)
  $game.events.on('policeComputerSelectEntry', onSelectEntry)
  $game.events.on('policeComputerRecordExpired', onRecordExpired)
  $game.api.engineLua('gameplay_policeComputer.requestState()')
})

onUnmounted(() => {
  $game.events.off('policeComputerState', onStateUpdate)
  $game.events.off('policeComputerScan', onScanResult)
  $game.events.off('policeComputerLookup', onLookupResult)
  $game.events.off('policeComputerVisibility', onVisibilityChange)
  $game.events.off('policeComputerAlert', onAlert)
  $game.events.off('policeComputerStopInitiated', onStopInitiated)
  $game.events.off('policeComputerStopProgress', onStopProgress)
  $game.events.off('policeComputerRabbit', onRabbit)
  $game.events.off('policeComputerAhead', onAhead)
  $game.events.off('policeComputerStopPrompt', onStopPrompt)
  $game.events.off('policeComputerStopActionMenu', onStopActionMenu)
  $game.events.off('policeComputerStopActionMenuConfirmed', onStopActionMenuConfirmed)
  $game.events.off('policeComputerCycleEntry', onCycleEntry)
  $game.events.off('policeComputerSelectEntry', onSelectEntry)
  $game.events.off('policeComputerRecordExpired', onRecordExpired)
  const uiNav = getUINavServiceInstance()
  if (uiNav && stopActionPreviousScope !== null && stopActionPreviousScope !== undefined) {
    uiNav.setActiveScope(stopActionPreviousScope)
    stopActionPreviousScope = null
  }
  if (actionBannerTimeout) clearTimeout(actionBannerTimeout)
  stopActionRadialRenderer.dispose()
})
</script>

<style scoped lang="scss">
$bg-dark: rgba(10, 14, 20, 0.98);
$bg-panel: rgba(15, 22, 35, 0.99);
$border-color: rgba(40, 80, 140, 0.5);
$text-primary: #c8d8e8;
$text-secondary: #7a8ea0;
$text-accent: #4a9eff;
$alert-red: #ff3c3c;
$alert-glow: rgba(255, 60, 60, 0.3);
$clear-green: #3cff6e;

.stop-action-overlay {
  position: fixed;
  inset: 0;
  display: flex;
  flex-flow: column;
  align-items: center;
  justify-content: flex-start;
  color: var(--bng-off-white);
  background: rgba(0, 0, 0, 0.2);
  padding: 2em 0;
  z-index: 120;
  pointer-events: auto;
}

.stop-action-menu {
  display: flex;
  flex-flow: column;
  align-items: center;
  width: 100%;
  height: 100%;
}

.stop-action-infos {
  margin-top: 0.5em;
  margin-bottom: 0.5em;
}

.stop-action-title {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-family: 'Overpass', 'Segoe UI', sans-serif;
  font-size: 2.1em;
  font-weight: 700;
  font-style: italic;
  letter-spacing: 0.03em;
  text-transform: none;
  color: var(--bng-off-white);
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.6);
}

.stop-action-title-accent {
  width: 0.35em;
  height: 1.1em;
  border-radius: 0.08em;
  background: var(--bng-orange);
  display: inline-block;
}

.stop-action-radial {
  display: block;
  min-width: 450px;
  height: 450px;
  position: absolute;
  top: calc(55% - 225px);
  margin: auto;
  pointer-events: auto;
}

.police-computer {
  font-family: 'Consolas', 'Courier New', monospace;
  font-size: 18px;
  color: $text-primary;
  background: $bg-dark;
  border: 1px solid $border-color;
  border-radius: 4px;
  min-width: 400px;
  max-width: 460px;
  overflow: hidden;
  user-select: none;

  &.collapsed {
    .pc-header {
      border-bottom: none;
    }
  }
}

.pc-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 6px 10px;
  background: linear-gradient(180deg, rgba(20, 35, 60, 0.95) 0%, $bg-dark 100%);
  border-bottom: 1px solid $border-color;
  cursor: pointer;
}

.pc-title {
  display: flex;
  align-items: center;
  gap: 8px;
}

.pc-badge {
  background: $text-accent;
  color: #000;
  font-weight: bold;
  font-size: 10px;
  padding: 2px 6px;
  border-radius: 2px;
  letter-spacing: 1px;
}

.pc-label {
  font-size: 14px;
  font-weight: bold;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.cone-indicators {
  display: flex;
  align-items: center;
  gap: 2px;
  margin-left: 4px;
}

.cone-icon {
  font-size: 14px;
  font-weight: bold;
  color: rgba(122, 142, 160, 0.3);
  transition: color 0.15s ease, text-shadow 0.15s ease;
  line-height: 1;

  &.active {
    color: $clear-green;
    text-shadow: 0 0 6px rgba(60, 255, 110, 0.6);
  }
}

.pc-controls {
  display: flex;
  align-items: center;
  gap: 8px;
}

.anpr-toggle {
  background: rgba(255, 60, 60, 0.2);
  color: $alert-red;
  border: 1px solid rgba(255, 60, 60, 0.4);
  padding: 2px 10px;
  border-radius: 2px;
  font-family: inherit;
  font-size: 12px;
  font-weight: bold;
  cursor: pointer;
  letter-spacing: 1px;
  transition: all 0.2s ease;

  &.active {
    background: rgba(60, 255, 110, 0.2);
    color: $clear-green;
    border-color: rgba(60, 255, 110, 0.4);
    box-shadow: 0 0 8px rgba(60, 255, 110, 0.3);
  }
}

.minimize-btn {
  background: rgba(74, 158, 255, 0.15);
  color: $text-secondary;
  border: 1px solid rgba(74, 158, 255, 0.3);
  padding: 1px 8px;
  border-radius: 2px;
  font-family: inherit;
  font-size: 12px;
  cursor: pointer;
  line-height: 1;
  transition: all 0.15s ease;

  &:hover {
    background: rgba(74, 158, 255, 0.3);
    color: $text-primary;
  }
}

.pc-body {
}

.plates-list {
  border-bottom: 1px solid $border-color;
}

.plate-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 5px 10px;
  border-bottom: 1px solid rgba(40, 80, 140, 0.2);
  cursor: pointer;
  transition: background 0.15s ease;

  &:hover {
    background: rgba(74, 158, 255, 0.1);
  }

  &.selected {
    background: rgba(74, 158, 255, 0.15);
    border-left: 2px solid $text-accent;
    padding-left: 8px;
  }

  &.ahead {
    background: rgba(74, 158, 255, 0.2);
    border-left: 2px solid $text-accent;
    padding-left: 8px;

    .plate-number {
      color: $text-accent;
    }
  }

  &.flagged {
    animation: flagPulse 2s ease-in-out infinite;

    .plate-number {
      color: $alert-red;
    }
  }
}

.plate-number {
  font-weight: bold;
  flex: 0 0 100px;
  letter-spacing: 1px;
}

.plate-vehicle {
  flex: 1;
  color: $text-secondary;
  min-width: 0;
  font-size: 16px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.plate-status {
  flex: 0 0 24px;
  text-align: center;
  font-weight: bold;
  font-size: 16px;

  &.status-clear {
    color: $clear-green;
  }

  &.status-alert {
    color: $alert-red;
    animation: alertGlow 1s ease-in-out infinite alternate;
  }
}

.plates-empty {
  padding: 16px;
  text-align: center;
  color: $text-secondary;
  font-style: italic;
}

.detail-close {
  position: absolute;
  top: 4px;
  right: 8px;
  font-size: 18px;
  color: $text-secondary;
  cursor: pointer;
  line-height: 1;

  &:hover {
    color: $text-primary;
  }
}

// Detail panel
.detail-panel {
  position: relative;
  padding: 8px 10px;
  background: $bg-panel;
  border-top: 1px solid $border-color;

  &.detail-flagged {
    border-top: 2px solid $alert-red;
    box-shadow: inset 0 2px 12px $alert-glow;
  }
}

.alerts-banner {
  margin-bottom: 8px;
}

.alert-item {
  background: rgba(255, 60, 60, 0.15);
  border: 1px solid rgba(255, 60, 60, 0.4);
  color: $alert-red;
  font-weight: bold;
  font-size: 11px;
  padding: 4px 8px;
  margin-bottom: 4px;
  text-align: center;
  letter-spacing: 1px;
  animation: alertFlash 1.5s ease-in-out infinite;
}

.detail-section {
  margin-bottom: 8px;

  &:last-child {
    margin-bottom: 0;
  }
}

.detail-heading {
  color: $text-accent;
  font-size: 12px;
  font-weight: bold;
  text-transform: uppercase;
  letter-spacing: 1.5px;
  margin-bottom: 4px;
  padding-bottom: 2px;
  border-bottom: 1px solid rgba(74, 158, 255, 0.2);
}

.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 16px;
  padding: 3px 0;
  font-size: 16px;
}

.detail-label {
  color: $text-secondary;
  flex: 0 0 120px;
}

.detail-value {
  flex: 1;
  color: $text-primary;
  font-weight: bold;
  text-align: right;
}

.value-alert {
  color: $alert-red;
}

.prior-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 2px 0;
  font-size: 12px;
}

.prior-year {
  color: $text-secondary;
  min-width: 36px;
}

.prior-offense {
  flex: 1;
}

.prior-severity {
  font-size: 9px;
  font-weight: bold;
  text-transform: uppercase;
  padding: 1px 4px;
  border-radius: 2px;

  &.severity-minor {
    color: #ffcc00;
    background: rgba(255, 204, 0, 0.15);
  }

  &.severity-major {
    color: #ff8800;
    background: rgba(255, 136, 0, 0.15);
  }

  &.severity-felony {
    color: $alert-red;
    background: rgba(255, 60, 60, 0.15);
  }
}

.wanted-banner, .stolen-banner {
  text-align: center;
  font-weight: bold;
  font-size: 13px;
  padding: 6px;
  letter-spacing: 2px;
  border-radius: 2px;
  animation: alertFlash 1.5s ease-in-out infinite;
}

.wanted-banner {
  background: rgba(255, 60, 60, 0.2);
  border: 1px solid $alert-red;
  color: $alert-red;
}

.stolen-banner {
  background: rgba(255, 136, 0, 0.2);
  border: 1px solid #ff8800;
  color: #ff8800;
}

.apb-banner {
  text-align: center;
  font-weight: bold;
  font-size: 12px;
  padding: 5px;
  letter-spacing: 1px;
  border-radius: 2px;
  background: rgba(255, 204, 0, 0.15);
  border: 1px solid rgba(255, 204, 0, 0.5);
  color: #ffcc00;
  animation: alertFlash 1.5s ease-in-out infinite;
}

// Action banner
.action-banner {
  padding: 5px 10px;
  text-align: center;
  font-weight: bold;
  font-size: 13px;
  letter-spacing: 1.5px;
  animation: alertFlash 1s ease-in-out infinite;

  &.action-danger {
    background: rgba(255, 60, 60, 0.2);
    border-bottom: 1px solid rgba(255, 60, 60, 0.5);
    color: $alert-red;
  }

  &.action-info {
    background: rgba(74, 158, 255, 0.15);
    border-bottom: 1px solid rgba(74, 158, 255, 0.3);
    color: $text-accent;
  }
}

// Stop progress
.stop-progress {
  position: relative;
  height: 18px;
  background: rgba(15, 22, 35, 0.9);
  border-bottom: 1px solid $border-color;
  overflow: hidden;
}

.stop-progress-bar {
  position: absolute;
  top: 0;
  left: 0;
  height: 100%;
  background: rgba(74, 158, 255, 0.25);
  transition: width 0.1s linear;
}

.stop-progress-label {
  position: relative;
  display: block;
  text-align: center;
  font-size: 11px;
  font-weight: bold;
  letter-spacing: 1px;
  line-height: 18px;
  color: $text-accent;
}

// Animations
@keyframes flagPulse {
  0%, 100% { background: transparent; }
  50% { background: rgba(255, 60, 60, 0.08); }
}

@keyframes alertGlow {
  from { text-shadow: 0 0 4px $alert-red; }
  to { text-shadow: 0 0 10px $alert-red, 0 0 16px rgba(255, 60, 60, 0.4); }
}

@keyframes alertFlash {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.7; }
}

.pc-toolbar {
  display: flex;
  gap: 6px;
  padding: 6px 8px;
  border-top: 1px solid $border-color;
}

.toolbar-btn {
  flex: 1;
  background: rgba(40, 80, 140, 0.2);
  color: $text-accent;
  border: 1px solid rgba(40, 80, 140, 0.4);
  padding: 4px 8px;
  border-radius: 2px;
  font-family: inherit;
  font-size: 11px;
  font-weight: bold;
  cursor: pointer;
  letter-spacing: 0.5px;
  transition: all 0.2s ease;

  &:hover {
    background: rgba(40, 80, 140, 0.4);
    border-color: $text-accent;
  }
}

@media (max-width: 900px) {
  .stop-action-title {
    font-size: 1.5em;
  }

  .stop-action-menu {
    width: 100%;
    height: 100%;
  }

  .stop-action-radial {
    min-width: 320px;
    height: 320px;
    top: calc(55% - 160px);
  }
}
</style>
