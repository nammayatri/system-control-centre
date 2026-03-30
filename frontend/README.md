# Autopilot Releases App

A React + TypeScript frontend built with Vite, Tailwind CSS, and Monaco Editor.

## Prerequisites

- **Node.js** >= 20.19 (22+ recommended)
- **npm** (comes with Node.js)

## Local Setup

1. **Install dependencies**

   ```bash
   npm install
   ```

2. **Create environment file**

   Create a `.env` file in the project root:

   ```env
   VITE_API_BASE_URL=http://localhost:8012
   ```

3. **Start the dev server**

   ```bash
   npm run dev
   ```

   The app will be available at `http://localhost:5173`.

## Environment Variables

| Variable | Description | Local Default |
|---|---|---|
| `VITE_API_BASE_URL` | Backend API base URL | `http://localhost:8012` |
| `VITE_AUTH_API_BASE_URL` | Auth API base URL (optional, derived from API base URL if not set) | — |

## Scripts

| Command | Description |
|---|---|
| `npm run dev` | Start Vite dev server |
| `npm run build` | Type-check and build for production |
| `npm run preview` | Preview the production build locally |

## Docker

```bash
docker build --build-arg VITE_API_BASE_URL=http://localhost:8012 -t autopilot .
docker run -p 80:80 autopilot
```

## Tech Stack

- React 19
- TypeScript
- Vite 7
- Tailwind CSS 4
- Monaco Editor
- React Router 7
- Axios
