import { expect, test, type APIRequestContext, type Page } from '@playwright/test'

const adminEmail = process.env.E2E_ADMIN_EMAIL ?? 'admin@example.com'
const mailpitURL = process.env.MAILPIT_URL ?? 'http://127.0.0.1:8025'

async function loginAsAdmin(page: Page, request: APIRequestContext) {
  await page.goto('/admin/login')
  await page.locator('input[name="email"]').fill(adminEmail)
  await page.getByRole('button', { name: 'Send magic link' }).click()
  await expect(page.getByRole('heading', { name: 'Check your email' })).toBeVisible()

  const list = await request
    .get(`${mailpitURL}/api/v1/messages`, { params: { to: adminEmail } })
    .then((response) => response.json())
  const messageID = list.messages?.[0]?.ID
  expect(messageID, 'admin magic-link email in Mailpit').toBeTruthy()

  const message = await request
    .get(`${mailpitURL}/api/v1/message/${messageID}`)
    .then((response) => response.json())
  const body = `${message.HTML ?? ''} ${message.Text ?? ''}`.replace(/&amp;/g, '&')
  const link = body.match(/https?:\/\/[^\s"'<>]+admin\/verify\?[^\s"'<>]+/)?.[0]
  expect(link, 'admin verification link in email').toBeTruthy()

  await page.goto(link!)
  await expect(page).toHaveURL(/\/admin$/)
}

test('unauthenticated admin pages redirect to login', async ({ page }) => {
  for (const path of [
    '/admin',
    '/admin/users',
    '/admin/recipes',
    '/admin/imports',
    '/admin/audit',
  ]) {
    await page.goto(path)
    await expect(page).toHaveURL(/\/admin\/login$/)
  }
})

test('admin can sign in and open the dashboard', async ({ page, request }) => {
  await loginAsAdmin(page, request)
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible()
  await expect(page.getByRole('link', { name: 'Imports' })).toBeVisible()
})

test('admin creates a user and the action is audited', async ({ page, request }) => {
  await loginAsAdmin(page, request)
  const email = `e2e-${Date.now()}@example.com`

  await page.goto('/admin/users/new')
  await page.locator('input[name="email"]').fill(email)
  await page.locator('input[name="displayName"]').fill('E2E User')
  await page.getByRole('button', { name: 'Create user' }).click()

  await expect(page).toHaveURL(/\/admin\/users$/)
  await expect(page.getByRole('cell', { name: email })).toBeVisible()

  await page.goto('/admin/audit')
  await expect(page.getByText('admin.user.create')).toBeVisible()
})

test('admin can run a queued import', async ({ page, request }) => {
  await loginAsAdmin(page, request)
  const url = `https://example.com/recipes/e2e-${Date.now()}`

  await page.goto('/admin/imports/new')
  await page.locator('input[name="url"]').fill(url)
  await page.getByRole('button', { name: 'Create import' }).click()
  await expect(page).toHaveURL(/\/admin\/imports$/)

  const row = page.locator('tr', { hasText: url })
  await expect(row.getByRole('button', { name: 'Run' })).toBeVisible()
  await row.getByRole('button', { name: 'Run' }).click()
  await expect(page.getByRole('heading', { name: 'Import started' })).toBeVisible()

  await page.goto('/admin/audit')
  await expect(page.getByText('admin.import.run')).toBeVisible()
})

test('POST actions without CSRF are rejected', async ({ page, request }) => {
  await loginAsAdmin(page, request)
  const response = await request.post('/admin/users', {
    data: { email: `csrf-${Date.now()}@example.com`, displayName: 'Blocked' },
    maxRedirects: 0,
  })
  expect(response.status()).toBe(403)
})
