<template>
  <div class="police-computer bng-app" v-show="isVisible" :class="{ collapsed: isCollapsed }">
    <!-- Header - always visible -->
    <div class="pc-header" @click="toggleCollapse">
      <div class="pc-title">
        <span class="pc-badge">ANPR</span>
        <span class="pc-label">Police Computer</span>
      </div>
      <div class="pc-controls">
        <button
          class="anpr-toggle"
          :class="{ active: anprActive }"
          @click.stop="toggleANPR">
          {{ anprActive ? 'ON' : 'OFF' }}
        </button>
        <span class="collapse-icon">{{ isCollapsed ? '&#9650;' : '&#9660;' }}</span>
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
          :key="entry.plate"
          :class="{ flagged: entry.flagged, selected: selectedPlate === entry.plate, ahead: aheadPlate === entry.plate }"
          @click="selectPlate(entry.plate)">
          <span class="plate-number">{{ entry.plate }}</span>
          <span class="plate-vehicle">{{ truncate(entry.vehicleName, 14) }}</span>
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
</template>

<script setup>
import { ref, reactive, onMounted, onUnmounted } from 'vue'
import { useLibStore } from '@/services'

const { $game } = useLibStore()

const isVisible = ref(false)
const isCollapsed = ref(false)
const anprActive = ref(false)
const scannedPlates = ref([])
const selectedPlate = ref(null)
const selectedRecord = ref(null)
const actionBanner = ref(null)
const stopProgress = ref(null)
const aheadPlate = ref(null)
let actionBannerTimeout = null

function toggleCollapse() {
  isCollapsed.value = !isCollapsed.value
}

function toggleANPR() {
  $game.api.engineLua('gameplay_policeComputer.toggleANPR()')
}

function selectPlate(plate) {
  if (selectedPlate.value === plate) {
    selectedPlate.value = null
    selectedRecord.value = null
    return
  }
  selectedPlate.value = plate
  const safePlate = plate.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  $game.api.engineLua(`gameplay_policeComputer.lookupPlate("${safePlate}")`)
}

function truncate(str, len) {
  if (!str) return ''
  return str.length > len ? str.substring(0, len) + '...' : str
}

function onStateUpdate(data) {
  anprActive.value = data.anprActive
  if (data.scannedPlates) {
    scannedPlates.value = data.scannedPlates
  }
}

function onScanResult(data) {
  if (!data || !data.record) return

  // Add to front of list, remove duplicate if exists
  const existing = scannedPlates.value.findIndex(p => p.plate === data.record.plate)
  if (existing >= 0) {
    scannedPlates.value.splice(existing, 1)
  }
  scannedPlates.value.unshift({
    plate: data.record.plate,
    vehicleName: data.record.vehicleName,
    flagged: data.record.flagged
  })

  // Trim to max
  if (scannedPlates.value.length > 12) {
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
}

function onVisibilityChange(data) {
  isVisible.value = data.visible
  if (!data.visible) {
    // Reset state when hiding
    selectedPlate.value = null
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
  if (actionBannerTimeout) clearTimeout(actionBannerTimeout)
})
</script>

<style scoped lang="scss">
$bg-dark: rgba(10, 14, 20, 0.92);
$bg-panel: rgba(15, 22, 35, 0.95);
$border-color: rgba(40, 80, 140, 0.5);
$text-primary: #c8d8e8;
$text-secondary: #7a8ea0;
$text-accent: #4a9eff;
$alert-red: #ff3c3c;
$alert-glow: rgba(255, 60, 60, 0.3);
$clear-green: #3cff6e;

.police-computer {
  font-family: 'Consolas', 'Courier New', monospace;
  font-size: 12px;
  color: $text-primary;
  background: $bg-dark;
  border: 1px solid $border-color;
  border-radius: 4px;
  min-width: 280px;
  max-width: 320px;
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
  font-size: 12px;
  font-weight: bold;
  text-transform: uppercase;
  letter-spacing: 0.5px;
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
  font-size: 10px;
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

.collapse-icon {
  font-size: 10px;
  color: $text-secondary;
}

.pc-body {
  max-height: 400px;
  overflow-y: auto;
}

.plates-list {
  border-bottom: 1px solid $border-color;
}

.plate-row {
  display: flex;
  align-items: center;
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
  width: 90px;
  letter-spacing: 1px;
}

.plate-vehicle {
  flex: 1;
  color: $text-secondary;
  font-size: 11px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.plate-status {
  width: 20px;
  text-align: center;
  font-weight: bold;
  font-size: 14px;

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

// Detail panel
.detail-panel {
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
  font-size: 10px;
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
  padding: 1px 0;
  font-size: 11px;
}

.detail-label {
  color: $text-secondary;
}

.detail-value {
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
  font-size: 11px;
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
  font-size: 11px;
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
  font-size: 9px;
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
</style>
