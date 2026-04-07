# Autopilot Releases App

A React + TypeScript frontend built with Vite, Tailwind CSS, and Monaco Editor.

## Local Setup (recommended)

The frontend starts automatically as part of the backend's `sc-dev` stack:

```bash
cd ../backend
nix develop          # auto via direnv
sc-dev               # starts postgres + backend + frontend together
```

This brings up the frontend on `http://localhost:5173` (or 5174 if 5173 is in use)
alongside the backend API on `http://localhost:8012`.

## Standalone (without backend stack)

If you want to run only the frontend (e.g. against a remote backend):

### Prerequisites
- **Node.js** >= 20.19 (22+ recommended)
- **npm** (comes with Node.js)

### Steps
1. **Install dependencies**
   ```bash
   npm install
   ```

2. **Create environment file** (optional — defaults to localhost:8012)
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
