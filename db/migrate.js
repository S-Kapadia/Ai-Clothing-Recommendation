const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', 'api', '.env') });

const fs = require('fs');
const mysql = require('mysql2/promise');

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

function splitStatements(sql) {
  const withoutComments = sql
    .split('\n')
    .filter((line) => !line.trim().startsWith('--'))
    .join('\n');

  return withoutComments
    .split(';')
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}

async function main() {
  const connection = await mysql.createConnection({
    host: process.env.DB_HOST,
    port: process.env.DB_PORT || 3306,
    user: process.env.DB_USER,
    password: process.env.DB_PASS,
    database: process.env.DB_NAME,
  });

  await connection.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id INT AUTO_INCREMENT PRIMARY KEY,
      filename VARCHAR(255) NOT NULL UNIQUE,
      applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);

  const [rows] = await connection.query('SELECT filename FROM schema_migrations');
  const applied = new Set(rows.map((row) => row.filename));

  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((file) => file.endsWith('.sql'))
    .sort();

  for (const file of files) {
    if (applied.has(file)) continue;

    const statements = splitStatements(fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8'));

    console.log(`Applying ${file}...`);
    await connection.beginTransaction();
    try {
      for (const statement of statements) {
        await connection.query(statement);
      }
      await connection.query('INSERT INTO schema_migrations (filename) VALUES (?)', [file]);
      await connection.commit();
      console.log(`Applied ${file}`);
    } catch (err) {
      await connection.rollback();
      throw err;
    }
  }

  await connection.end();
  console.log('All migrations applied.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
