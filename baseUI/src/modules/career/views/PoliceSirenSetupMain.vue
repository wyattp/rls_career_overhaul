<template>
  <ComputerWrapper :path="['Police Siren Setup']" title="Police Siren Setup" back @back="goBack">
    <BngCard class="siren-setup-card" v-bng-blur="1">
      <div v-if="error" class="error-msg">{{ error }}</div>
      <div v-else-if="setupData" class="siren-setup-content">
        <div class="vehicle-name">{{ setupData.vehicleName }}</div>

        <div class="field-row">
          <label>Primary Siren</label>
          <div class="dropdown-with-preview">
            <BngDropdown v-model="primaryAudio" :items="setupData.options" />
            <BngButton class="preview-btn" @click="preview(primaryAudio)" :accent="ACCENTS.secondary">&#9654;</BngButton>
          </div>
        </div>

        <div class="field-row">
          <label>Secondary Siren</label>
          <div class="dropdown-with-preview">
            <BngDropdown v-model="secondaryAudio" :items="setupData.options" />
            <BngButton class="preview-btn" @click="preview(secondaryAudio)" :accent="ACCENTS.secondary">&#9654;</BngButton>
          </div>
        </div>

        <div class="button-row">
          <BngButton @click="save" :accent="ACCENTS.attention">Save</BngButton>
          <BngButton @click="goBack" :accent="ACCENTS.secondary">Cancel</BngButton>
        </div>
      </div>
      <div v-else class="loading-msg">Loading...</div>
    </BngCard>
  </ComputerWrapper>
</template>

<script setup>
import { ref, onMounted } from "vue"
import { BngCard, BngButton, BngDropdown, ACCENTS } from "@/common/components/base"
import { vBngBlur } from "@/common/directives"
import ComputerWrapper from "./ComputerWrapper.vue"
import { lua } from "@/bridge"

const setupData = ref(null)
const primaryAudio = ref("")
const secondaryAudio = ref("")
const error = ref(null)

onMounted(async () => {
  const result = await lua.career_modules_policeSirenSetup.getSetupData()
  if (!result || !result.ok) {
    error.value = result ? result.reason : "Failed to load setup data"
    return
  }
  setupData.value = result
  primaryAudio.value = result.primaryAudio || (result.options[0] && result.options[0].value) || ""
  secondaryAudio.value = result.secondaryAudio || (result.options[1] && result.options[1].value) || ""
})

function preview(partName) {
  if (!partName) return
  lua.career_modules_policeSirenSetup.previewSiren(partName)
}

async function save() {
  if (!setupData.value) return
  lua.career_modules_policeSirenSetup.stopPreview()
  await lua.career_modules_policeSirenSetup.setSetupData(setupData.value.inventoryId, {
    primaryAudio: primaryAudio.value,
    secondaryAudio: secondaryAudio.value,
  })
  goBack()
}

function goBack() {
  lua.career_modules_policeSirenSetup.stopPreview()
  lua.career_modules_policeSirenSetup.closeMenu()
}
</script>

<style lang="scss" scoped>
.siren-setup-card {
  max-width: 40rem;
}

.siren-setup-content {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
  padding: 1rem;
}

.vehicle-name {
  font-size: 1.2rem;
  font-weight: bold;
  color: white;
}

.field-row {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;

  label {
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.9rem;
  }
}

.dropdown-with-preview {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  overflow: hidden;

  :deep(.bng-dropdown) {
    flex: 1;
    min-width: 0;
  }
}

.preview-btn {
  flex-shrink: 0;
  min-width: 2.5rem;
  padding: 0.4rem 0.6rem;
  font-size: 1rem;
}

.button-row {
  display: flex;
  gap: 1rem;
  margin-top: 0.5rem;
}

.error-msg {
  color: #ff6b6b;
  padding: 1rem;
}

.loading-msg {
  color: rgba(255, 255, 255, 0.6);
  padding: 1rem;
}
</style>
