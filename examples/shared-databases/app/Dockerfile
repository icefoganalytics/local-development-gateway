FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts && npm cache clean --force
COPY *.mjs ./
COPY migrations ./migrations
USER node
CMD ["node", "app.mjs"]
