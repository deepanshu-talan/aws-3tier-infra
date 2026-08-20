FROM golang:1.26.6-alpine AS builder

WORKDIR /app

# Copy go mod and sum files
COPY go.mod go.sum* ./

# Download dependencies
RUN go mod download

# Copy source code
COPY main.go ./

# For static analysis
# RUN go vet -v

# Build the application CGO_ENABLED=0 for removeing c library dependencies
RUN CGO_ENABLED=0  go build -o backend-app

# Using a distroless base image to create a minimal runtime image
FROM gcr.io/distroless/static-debian12:nonroot@sha256:6447365a6337c3732f412d1b74357b30a633831955b2bc45552b0086be907687

WORKDIR /app

# Copy the compiled binary from the builder stage
COPY --from=builder /app/backend-app .

# Expose port 8080
EXPOSE 8080

# Command to run the executable
CMD ["./backend-app"]