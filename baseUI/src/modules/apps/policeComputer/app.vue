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

  <div class="stop-action-overlay" v-if="stopActionMenu.open">
    <div class="stop-action-menu">
      <div
        class="stop-action-option option-up"
        :class="{ selected: stopActionMenu.selection === 'up' }">
        <svg class="stop-action-icon" viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="7" cy="12" r="4.1" />
          <circle cx="17" cy="12" r="4.1" />
          <path d="M11 12h2" />
        </svg>
        <span class="stop-action-label">Arrest</span>
      </div>

      <div
        class="stop-action-option option-right"
        :class="{ selected: stopActionMenu.selection === 'right' }">
        <svg class="stop-action-icon" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M12 3l9 16H3z" />
          <path d="M12 9v5" />
          <circle cx="12" cy="17" r="0.8" />
        </svg>
        <span class="stop-action-label">Warning/Detain</span>
      </div>

      <div
        class="stop-action-option option-down"
        :class="{ selected: stopActionMenu.selection === 'down' }">
        <svg class="stop-action-icon" viewBox="0 0 24 24" aria-hidden="true">
          <rect x="4" y="10" width="16" height="10" rx="2" />
          <path d="M8 10V7a4 4 0 0 1 6.9-2.7" />
          <path d="M16.5 5.7l-2 0.1V3.8" />
        </svg>
        <span class="stop-action-label">Go Free</span>
      </div>

      <div
        class="stop-action-option option-left"
        :class="{ selected: stopActionMenu.selection === 'left' }">
        <svg class="stop-action-icon" viewBox="0 0 24 24" aria-hidden="true">
          <rect x="4" y="6" width="16" height="12" rx="1.8" />
          <path d="M7 10h10" />
          <path d="M7 13h7" />
        </svg>
        <span class="stop-action-label">Ticket</span>
      </div>

      <div class="stop-action-center">
        <span class="center-title">Stop Action</span>
        <span class="center-plate" v-if="stopActionMenu.plate">{{ stopActionMenu.plate }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, reactive, onMounted, onUnmounted } from 'vue'
import { useLibStore } from '@/services'

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
  selection: 'up'
})
let actionBannerTimeout = null
const STOP_ACTION_MENU_DEFAULT = 'up'
const STOP_ACTION_MENU_LABELS = {
  up: 'Arrest',
  down: 'Go Free',
  left: 'Ticket',
  right: 'Warning/Detain'
}

function normalizeStopActionSelection(selection) {
  if (selection === 'up' || selection === 'down' || selection === 'left' || selection === 'right') {
    return selection
  }
  return STOP_ACTION_MENU_DEFAULT
}

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
    stopActionMenu.selection = STOP_ACTION_MENU_DEFAULT
    return
  }

  stopActionMenu.open = !!data.open
  stopActionMenu.targetVehId = Number.isFinite(Number(data.targetVehId)) ? Number(data.targetVehId) : null
  stopActionMenu.plate = data.plate || null
  stopActionMenu.selection = normalizeStopActionSelection(data.selection)
}

function onStopActionMenuConfirmed(data) {
  if (!data) return
  const selectedAction = normalizeStopActionSelection(data.action)
  const label = STOP_ACTION_MENU_LABELS[selectedAction] || 'Unknown'
  const plateSuffix = data.plate ? ` - ${data.plate}` : ''
  showActionBanner('info', `STOP ACTION SELECTED: ${label.toUpperCase()}${plateSuffix}`, 2200)
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
  $game.events.off('policeComputerStopActionMenu', onStopActionMenu)
  $game.events.off('policeComputerStopActionMenuConfirmed', onStopActionMenuConfirmed)
  $game.events.off('policeComputerCycleEntry', onCycleEntry)
  $game.events.off('policeComputerSelectEntry', onSelectEntry)
  $game.events.off('policeComputerRecordExpired', onRecordExpired)
  if (actionBannerTimeout) clearTimeout(actionBannerTimeout)
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
$overlay-dark: rgba(18, 20, 26, 0.58);

.stop-action-overlay {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: $overlay-dark;
  z-index: 120;
  pointer-events: none;
}

.stop-action-menu {
  position: relative;
  width: 380px;
  height: 380px;
  border-radius: 50%;
  border: 1px solid rgba(190, 210, 236, 0.24);
  background: radial-gradient(circle at center, rgba(24, 31, 44, 0.74) 0%, rgba(12, 16, 24, 0.62) 72%, rgba(8, 11, 17, 0.4) 100%);
  box-shadow: 0 0 50px rgba(0, 0, 0, 0.45), inset 0 0 20px rgba(74, 158, 255, 0.14);
}

.stop-action-option {
  position: absolute;
  width: 132px;
  height: 84px;
  border-radius: 10px;
  border: 1px solid rgba(191, 204, 225, 0.26);
  background: rgba(20, 26, 36, 0.5);
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 5px;
  transition: border-color 0.12s ease, background 0.12s ease, box-shadow 0.12s ease, transform 0.12s ease;
  color: #f4f7fb;

  &.selected {
    border-color: rgba(210, 231, 255, 0.94);
    background: rgba(55, 87, 126, 0.48);
    box-shadow: 0 0 14px rgba(160, 207, 255, 0.34);
  }
}

.option-up {
  top: 16px;
  left: 50%;
  transform: translateX(-50%);
}

.option-right {
  right: 16px;
  top: 50%;
  transform: translateY(-50%);
}

.option-down {
  bottom: 16px;
  left: 50%;
  transform: translateX(-50%);
}

.option-left {
  left: 16px;
  top: 50%;
  transform: translateY(-50%);
}

.stop-action-icon {
  width: 24px;
  height: 24px;
  stroke: #ffffff;
  stroke-width: 1.8;
  fill: none;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.stop-action-label {
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  line-height: 1;
}

.stop-action-center {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 146px;
  height: 146px;
  border-radius: 50%;
  border: 1px solid rgba(188, 213, 243, 0.32);
  background: rgba(13, 18, 26, 0.74);
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 6px;
  text-align: center;
  box-shadow: inset 0 0 15px rgba(74, 158, 255, 0.16);
}

.center-title {
  font-size: 11px;
  color: rgba(206, 226, 248, 0.88);
  text-transform: uppercase;
  letter-spacing: 1.3px;
}

.center-plate {
  font-size: 14px;
  font-weight: bold;
  color: #f1f7ff;
  letter-spacing: 1.4px;
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
  .stop-action-menu {
    width: 320px;
    height: 320px;
  }

  .stop-action-option {
    width: 116px;
    height: 74px;
  }

  .stop-action-center {
    width: 126px;
    height: 126px;
  }

  .center-plate {
    font-size: 12px;
  }
}
</style>
