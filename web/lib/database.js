import { neon } from '@neondatabase/serverless';

let client;
let clientURL;

export function databaseConfigured(env = process.env) {
  return Boolean(env.DATABASE_URL);
}

export async function queryDatabase(text, params = [], env = process.env) {
  const databaseURL = env.DATABASE_URL;
  if (!databaseURL) throw new Error('Metrics database is not configured');
  if (!client || clientURL !== databaseURL) {
    client = neon(databaseURL);
    clientURL = databaseURL;
  }
  return client.query(text, params);
}

export async function deleteExpiredProductEvents(queryImpl = queryDatabase) {
  await queryImpl("delete from product_events where created_at < now() - interval '90 days'");
}
