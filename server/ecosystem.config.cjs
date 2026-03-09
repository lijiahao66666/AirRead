module.exports = {
  apps: [
    {
      name: 'airread',
      script: 'app.js',
      cwd: '/www/airread/server',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
      env: {
        NODE_ENV: 'production',
        PORT: 9000,
      },
    },
  ],
};