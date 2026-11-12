/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Verification builds set NEXT_DIST_DIR=.next-verify so they never
  // overwrite the running dev server's .next directory.
  distDir: process.env.NEXT_DIST_DIR || ".next",
  // Opt-in browser source maps for the production diagnostic build only:
  // NEXT_SOURCE_MAPS=1 NEXT_DIST_DIR=.next-prod npx next build
  productionBrowserSourceMaps: process.env.NEXT_SOURCE_MAPS === "1",
  allowedDevOrigins: ["127.0.0.1:50452", "localhost:3000"],
  experimental: {
    serverActions: {
      allowedOrigins: [
        "127.0.0.1:50452",
        "localhost:3000",
      ],
    },
  },
};

export default nextConfig;
