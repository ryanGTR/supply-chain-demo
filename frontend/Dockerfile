# ─────── Stage 1: build the SPA ───────
# 用 node:22-alpine：node:20-alpine 內建 npm 10.8.2 有 "Exit handler never
# called!" 的 crash bug，會讓 npm ci/install 在裝完前就掛掉、devDependencies
# （vue-tsc）沒裝成 → build 報 "vue-tsc: not found"。node:22 的 npm 正常。
FROM node:22-alpine AS build
WORKDIR /app

COPY package.json package-lock.json* ./
# 用 npm ci：依 lockfile 的可重現安裝（供應鏈 demo 該如此）。
RUN npm ci --no-audit --no-fund

COPY . .
RUN npm run build

# ─────── Stage 2: nginx serves the static SPA ───────
FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
