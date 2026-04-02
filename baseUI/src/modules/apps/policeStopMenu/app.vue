<template>
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
const STOP_ACTION_MENU_DEFAULT = 'up'
const STOP_ACTION_MENU_SCOPE = 'policeStopActionMenu'
const STOP_ACTION_STICK_THRESHOLD = 0.5
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
  $game.api.engineLua(`if gameplay_police then gameplay_police.selectStopActionMenu("${action}") end`)
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
  $game.api.engineLua('if gameplay_police and gameplay_police.cancelStopActionMenu then gameplay_police.cancelStopActionMenu() end')
}

function onStopMenuStick(data) {
  if (!stopActionMenu.open || !data) return
  const x = Number(data.x) || 0
  const y = Number(data.y) || 0

  const stickActiveBefore = stopActionStickActive
  stopActionStickX = x
  stopActionStickY = y
  stopActionStickActive = isStopActionStickActive(x, y)

  if (stopActionStickActive) {
    pointToStopActionItem(x, y)
  }

  if (!stopActionStickActive && stickActiveBefore) {
    pointToStopActionItem(0, 0)
  }
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

  if (data.reason === 'navigate') {
    stopActionMenu.selection = normalizeStopActionSelection(data.selection)
  } else {
    stopActionMenu.selection = null
  }
  nextTick(() => updateStopActionRadial())
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

onMounted(() => {
  $game.events.on('policeStopActionMenu', onStopActionMenu)
  $game.events.on('policeStopMenuStick', onStopMenuStick)
})

onUnmounted(() => {
  $game.events.off('policeStopActionMenu', onStopActionMenu)
  $game.events.off('policeStopMenuStick', onStopMenuStick)
  const uiNav = getUINavServiceInstance()
  if (uiNav && stopActionPreviousScope !== null && stopActionPreviousScope !== undefined) {
    uiNav.setActiveScope(stopActionPreviousScope)
    stopActionPreviousScope = null
  }
  stopActionRadialRenderer.dispose()
})
</script>

<style scoped lang="scss">
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

@media (max-width: 900px) {
  .stop-action-radial {
    min-width: 350px;
    height: 350px;
    top: calc(55% - 175px);
  }

  .stop-action-title {
    font-size: 1.6em;
  }
}
</style>
