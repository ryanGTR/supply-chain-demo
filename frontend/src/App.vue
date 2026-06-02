<script setup lang="ts">
import { ref, onMounted } from 'vue'
import axios from 'axios'

interface Product {
  id: number
  name: string
  price: number
}

const products = ref<Product[]>([])
const error = ref<string>('')
const loading = ref<boolean>(true)

onMounted(async () => {
  try {
    const res = await axios.get<Product[]>('/api/products')
    products.value = res.data
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <main>
    <h1>🛒 Products</h1>
    <p v-if="loading">Loading…</p>
    <p v-else-if="error" class="error">⚠️ {{ error }}</p>
    <ul v-else>
      <li v-for="p in products" :key="p.id">
        <span class="name">{{ p.name }}</span>
        <span class="price">${{ p.price.toFixed(2) }}</span>
      </li>
    </ul>
    <footer>Backend: OpenLiberty + Java 21 · Frontend: Vue 3 + Vite</footer>
  </main>
</template>

<style>
body {
  font-family: system-ui, -apple-system, sans-serif;
  margin: 0;
  padding: 2rem;
  background: #f5f5f7;
}
main {
  max-width: 600px;
  margin: 0 auto;
  background: white;
  padding: 2rem;
  border-radius: 12px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.05);
}
h1 {
  margin-top: 0;
}
ul {
  list-style: none;
  padding: 0;
}
li {
  display: flex;
  justify-content: space-between;
  padding: 0.75rem 0;
  border-bottom: 1px solid #eee;
}
.name {
  font-weight: 500;
}
.price {
  color: #0066cc;
  font-variant-numeric: tabular-nums;
}
.error {
  color: #c00;
}
footer {
  margin-top: 2rem;
  font-size: 0.8rem;
  color: #888;
  text-align: center;
}
</style>
