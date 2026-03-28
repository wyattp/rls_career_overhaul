<template>
  <ComputerWrapper :path="[computerStore.computerData.facilityName]" title="Police Siren Setup" back @back="close">
    <BngCard class="setup-card">
      <div class="setup-content">
        <div v-if="loading">Loading...</div>
        <div v-else-if="error" class="error">{{ error }}</div>
        <div v-else>
          <div class="vehicle-name">{{ setupData.vehicleName }}</div>
          <div class="field">
            <label for="primaryAudio">Primary Tone (Wail)</label>
            <BngDropdown v-model="primaryAudio" :items="setupData.options" />
          </div>
          <div class="field">
            <label for="secondaryAudio">Secondary Tone (Yelp)</label>
            <BngDropdown v-model="secondaryAudio" :items="setupData.options" />
          </div>
          <div class="actions">
            <BngButton :disabled="saving" @click="save">Save</BngButton>
          </div>
          <div v-if="saveMessage" class="save-message">{{ saveMessage }}</div>
        </div>
      </div>
    </BngCard>
  </ComputerWrapper>
</template>

<script setup>
import { ref, onMounted } from "vue"
import { lua } from "@/bridge"
import ComputerWrapper from "./ComputerWrapper.vue"
import { BngButton, BngCard, BngDropdown } from "@/common/components/base"
import { useComputerStore } from "../stores/computerStore"

const computerStore = useComputerStore()

const loading = ref(true)
const saving = ref(false)
const error = ref("")
const saveMessage = ref("")
const setupData = ref({
  vehicleName: "",
  options: [],
  inventoryId: null,
  primaryAudio: "",
  secondaryAudio: "",
})

const primaryAudio = ref("")
const secondaryAudio = ref("")

const load = async () => {
  loading.value = true
  error.value = ""
  saveMessage.value = ""
  try {
    const data = await lua.career_modules_policeSirenSetup.getSetupData(computerStore.activeInventoryId)
    if (!data || data.ok === false) {
      error.value = (data && data.reason) || "Unable to load police siren setup."
      return
    }
    setupData.value = data
    primaryAudio.value = data.primaryAudio || ""
    secondaryAudio.value = data.secondaryAudio || ""
  } catch (err) {
    error.value = "Unable to load police siren setup."
  } finally {
    loading.value = false
  }
}

const save = async () => {
  if (saving.value || !setupData.value.inventoryId) return
  saveMessage.value = ""
  saving.value = true
  try {
    const result = await lua.career_modules_policeSirenSetup.setSetupData(setupData.value.inventoryId, {
      primaryAudio: primaryAudio.value,
      secondaryAudio: secondaryAudio.value,
    })
    let ok = false
    let reason = ""
    if (Array.isArray(result)) {
      ok = !!result[0]
      reason = result[1] || ""
    } else {
      ok = !!result
    }
    saveMessage.value = ok ? "Saved." : (reason || "Could not save.")
  } catch (err) {
    saveMessage.value = "Could not save."
  } finally {
    saving.value = false
  }
}

const close = () => {
  lua.career_modules_policeSirenSetup.closeMenu()
}

onMounted(load)
</script>

<style scoped lang="scss">
.setup-card {
  min-width: 38rem;
  max-width: 100%;
}

.setup-content {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  padding: 1rem;
  color: white;
}

.vehicle-name {
  font-size: 1.1rem;
  font-weight: 600;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}


.actions {
  display: flex;
  justify-content: flex-end;
}

.error {
  color: #ff8f8f;
}

.save-message {
  color: #9ad7ff;
}
</style>
