/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  experimental: {
    serverActions: {
      allowedOrigins: ["127.0.0.1", "localhost"],
      allowedForwardedHosts: ["127.0.0.1", "localhost"],
    },
  },
};

export default nextConfig;
