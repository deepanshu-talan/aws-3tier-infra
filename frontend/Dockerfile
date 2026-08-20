# Build stage
FROM node:24-alpine AS build

WORKDIR /app

COPY package*.json ./
RUN npm install

COPY . .

# Production stage using distroless
FROM gcr.io/distroless/nodejs:24

WORKDIR /app

USER nonroot

# Copy only necessary files from build stage
COPY --from=build /app/server.js ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/public ./public

# If you have other necessary directories, add them here
# COPY --from=build /app/views ./views

EXPOSE 3000

CMD ["server.js"]