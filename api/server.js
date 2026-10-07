require('dotenv').config();
const express = require('express');
const pool = require('./db/pool');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.get('/health/db', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok' });
  } catch (err) {
    res.status(500).json({ status: 'error', message: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
