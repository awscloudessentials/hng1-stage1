# Dockerfile
FROM node:18-alpine

WORKDIR /usr/src/app

COPY package*.json ./
RUN npm ci --production

COPY . .

# If app uses PORT env:
ENV PORT=3000

# Healthcheck (optional)
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost:${PORT} || exit 1

EXPOSE 3000

# Start command (ensure app binds 0.0.0.0)
CMD ["node", "index.js"]
