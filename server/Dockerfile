# 1190 Chat relay server — production image
# Small, non-root, health-checked. Persists state under /data (mount a volume).
FROM node:20-alpine

ENV NODE_ENV=production \
    PORT=8090 \
    DATA_DIR=/data

WORKDIR /app

# Install production deps first for better layer caching.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Application code.
COPY server.js ./

# Data dir owned by the unprivileged 'node' user (ships with the base image).
RUN mkdir -p /data && chown -R node:node /data /app
USER node

EXPOSE 8090

# Container health check: GET /health must return 2xx.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
