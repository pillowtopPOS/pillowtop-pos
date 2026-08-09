/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
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
