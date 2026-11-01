SticksFight — Vercel deployment
1. Upload this folder to a GitHub repository.
2. Import the repository into Vercel (Framework Preset: Other).
3. Build Command: leave empty. Output Directory: .
4. Deploy.

Routes supported by the frontend:
  /home
  /profile
  /download
  /game

vercel.json rewrites routes to index.html so client-side navigation works.
Note: multiplayer matchmaking and server-backed profiles are not connected yet.
