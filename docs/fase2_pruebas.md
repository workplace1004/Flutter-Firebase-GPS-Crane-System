# Phase 2 — How to test it

Which apps changed, and how to test each one: automated tests, by hand against
the emulator or the dev project, and end to end on Firebase.

## What changed where

| Part | Changed? | What to test |
|---|---|---|
| **admin_web** (panel) | Yes, most of Phase 2 | Office screens (Aseguradoras, Tarifa base, Cortes, Facturación, Comprobantes NCF) and the insurer portal |
| **driver_app** | Yes | Insurer jobs ("Ganancia por este servicio", no cash), Mis cortes, Mi balance, balance chip on home |
| **client_app** | No screen changes | Only a quick check that nothing broke (it shares the core package) |
| **functions** + rules | Yes | Covered by the automated tests; checked end to end on Firebase |

## 1. Automated tests (do these first)

From the repo root, once: `flutter pub get`.

```bash
cd packages/grua_core && flutter analyze && flutter test
cd apps/admin_web     && flutter analyze && flutter test
cd apps/driver_app    && flutter analyze && flutter test
cd apps/client_app    && flutter analyze && flutter test
```

Backend (needs Java 21 for the emulators):

```bash
cd functions
npm install
npx tsc --noEmit -p .
npm run lint
npm run test:emulator
```

Every command should end with "No issues found" / "All tests passed".

The widget tests run against the in-memory backend in `packages/grua_testing`.
It is a dev dependency only: no app can be built with it.

Excel samples from the tests: after `flutter test` in `packages/grua_core`,
open `packages/grua_core/build/xlsx_samples/factura.xlsx` and `facturas.xlsx`
in Excel or Google Sheets.

## 2. By hand, against the emulator or the dev project

The apps always talk to Firebase. For a clean, throw-away run use the emulator
suite (needs Java 21):

```bash
firebase emulators:start
# then, in each app:
flutter run -d chrome --dart-define-from-file=../../config/dev.json --dart-define=USE_EMULATORS=true
```

Or leave out `USE_EMULATORS` to use the dev project. Either way the three apps
share one backend, so what you do in one shows up in the others.

**Before you start**, you need the office admin (see "Granting the first admin"
in the README) and, for the chofer checks, one chofer account with a truck,
created from the panel in **Choferes** and **Grúas**. Nothing is pre-loaded:
every company, user and tow below is one you create.

### 2.1 Admin panel — office

Run the panel on port 5000. Use a browser window at least 1024 px wide and
sign in with the office admin account.

**A. Aseguradoras**
1. Sidebar → **Aseguradoras**. Empty on a fresh project.
2. **Nueva aseguradora**. The form is in three blocks — Empresa, Contacto
   (folded behind **Agregar contacto**, since it is optional) and Pago al
   chofer:
   - type the RNC as bare digits `130000002` → it groups itself into
     `1-30-00000-2`, and **Crear aseguradora** answers "Ese RNC no es válido"
     (wrong check digit);
   - the share chips **65 / 70 / 75 / 80** fill the percentage, and the line
     under them says what that pays on a RD$2,500 tow;
   - with RNC `1-01-00157-7`, a billing email and share `65` → created.
3. Open the new company:
   - **Datos**: edit a field and save; **Suspender** with a reason → status
     changes; **Reactivar**.
   - **Usuarios** → **Agregar usuario** (name, email, role) → a temporary
     password is shown once. Add one **manager** and one **operator** and
     keep both passwords: section 2.2 signs in as them.
   - **Tarifa**: says it uses the base tariff. Change zone 1 price to `2000`,
     **Guardar tarifa** → "Precio negociado". Set a zone limit that leaves a
     gap (e.g. zone 2 "hasta" `5`) → error, nothing saved. **Usar la tarifa
     base** → back to the base prices (the fields show 2500 again).
   - Type a price without saving, switch to **Datos** and back → the typed
     price is still there.
4. **Tarifa base** (button at the top of Aseguradoras): the default table (0–10 / 10–25 / 25–50 / +50 km; ligero,
   SUV, pesado). The examples under the table (5 km, 20 km, 62 km) update as
   you type.

**B. Facturación and NCF**
Needs at least one finished tow of the company you created: order one in the
portal (2.2) and complete it in the chofer app (2.3) first.

1. Sidebar → **Facturación**. You should see:
   - the "Modo prueba" notice;
   - "Próximo NCF: B0100000001";
   - your company under **Por facturar**.
2. **Generar facturas** (last month, all companies) → **Emitir facturas** →
   message "Se emitió 1 factura con NCF de prueba (B0100000001)…".
3. The row shows the **NCF DE PRUEBA** badge and "Por cobrar". Open it:
   - issuer, client, RNCs, period, due date, every tow with claim number,
     subtotal + ITBIS 18% = total;
   - **Imprimir / PDF** opens a new tab (allow pop-ups). The page says
     "COMPROBANTE DE PRUEBA — SIN VALOR FISCAL". Use the browser's "Save as PDF";
   - **Exportar Excel** downloads `Factura_B0100000001_….xlsx`. Open it:
     sheets **Factura**, **Resumen por zona**, **Tarifa por zonas**. Change an
     amount in the Monto column: Subtotal, ITBIS and Total recalculate.
     The filter buttons work.
4. **Registrar cobro**: confirm with no number → error; type `TRF-123` →
   "Cobrada"; the pay/void buttons disappear.
5. Generate again for the **current month** (the dialog lists it) → a new
   invoice `B0100000002`. Open it → **Anular** with a reason → "Anulada";
   back on the list its tow is again under **Por facturar**. Generate again →
   `B0100000003` (a voided number is never reused).
6. Filters (Todas / Por cobrar / Vencidas / Cobradas / Anuladas) and the
   company dropdown. **Exportar Excel** on the list exports only what the
   filter shows; with nothing shown the button is disabled.

**C. Switching to the real NCF range**
1. **Facturación → Comprobantes (NCF)**.
2. Company: razón social, RNC `123456789` → "Ese RNC no es válido";
   `1-01-00157-7`, credit days `15` → saved.
3. Sequence: Desde `1`, Hasta `500`, vencimiento `31/12/2020` → "Esa fecha ya
   pasó"; `2099-12-31` → "Escribe la fecha como dd/mm/aaaa"; `31/12/2099` →
   "Primer NCF: B0100000001" → **Guardar secuencia real** → confirm.
4. The page says "Real, autorizada por la DGII". Back in Facturación the test
   notice is gone. Generate an invoice → NCF `B0100000001` **without** the
   test badge, "Válido hasta 31/12/2099", and your RNC on it.
5. Used-up range: save a real range with Desde = Hasta (e.g. `600`/`600`),
   generate one invoice, then try again → red notice "Se agotó la secuencia…"
   and the generate dialog shows the same error.

**D. Cortes (weekly settlement)**

Sidebar → **Cortes** → **Generar cortes ahora**. Each chofer's unsettled
jobs become a corte. Open one:
- the three sections (insurer jobs, cash commissions, final balance), like
  the Carlos example;
- **Registrar transferencia al chofer** (or **Registrar pago del chofer** when
  the chofer owes) needs the transfer or deposit number;
- **Anular** needs a reason and gives the jobs back.

**E. Messages**

Any confirmation or error in the panel — copying a code, issuing an invoice,
registering a payment, a refused action — appears as a small card at the **top
middle** of the window: green tick for something that worked, red for a
failure. It leaves on its own, and a new one replaces the last.

**F. Light and dark**
1. Top bar, left of your avatar: the sun icon. Press it → the whole panel goes
   dark (sidebar, cards, tables, dialogs and the live map), and the icon turns
   into a moon.
2. Reload the page → it opens dark again: the choice is kept in this browser.
3. The caret next to the icon opens **Claro / Oscuro / Como el sistema**. Pick
   **Como el sistema** and change your computer's theme → the panel follows.
4. Check a few pages in dark: Operaciones (map + queue), Facturación (an
   invoice), Cortes (a corte's balance banner) and any dialog.
5. The insurer portal has the same control in its top bar.

**G. Office service detail**

**Servicios** → open any finished job. The dialog has:
- a header with the code (and a button that copies it), the status and when it
  came in;
- four tiles: total, forma de pago, distancia y tiempo, chofer asignado;
- the record in two columns — who and what on the left, money and time on the
  right — with **Tiempos** drawn as a timeline and the total in bold;
- on an insurer's tow, an **Aseguradora** card (company, claim, policy,
  zone) and "Asegurado" instead of "Cliente";
- **Fotos del chofer**: the photos taken at pickup and at drop-off. Click
  one to see it full size.

### 2.2 Admin panel — insurer portal

Same run, another browser or an incognito window. Sign in as the manager and
the operator you added in 2.1.A.3. The first sign-in asks for a new password.

**As the operator**
1. You land on **Inicio**: company name at the top, month numbers (servicios,
   costo con ITBIS, tiempo promedio), "En curso", "Últimos servicios".
   The sidebar has no office pages, no Facturas and no Usuarios.
2. Type `localhost:5000/#/` or `…/#/facturas` in the address bar → you are
   sent back to the portal.
3. **Nuevo servicio**:
   - Press **Crear servicio** with the form empty → "Escribe el número de
     siniestro" and "Elige el punto de recogida y el destino".
   - Claim `SIN-2024-001489`, insured name, phone `809-555-0123`, plate.
   - Pickup and destination: type an address and pick Google's suggestion,
     or use the map button to point at the place. (Without a Places key
     there are no suggestions: point at it on the map.)
   - Price panel: "0–10 km · Vehículo ligero", RD$2,500 + ITBIS RD$450 =
     RD$2,950. Change the type to **Jeepeta** → RD$3,200.
   - **Crear servicio** → you land on the tow's detail page.
4. Order again with `sin 2024 001489` → "Ya hay una grúa en curso para ese
   número de siniestro".
5. **Mapa en vivo**: your tows in progress; click a card to focus it.
6. **Servicios**: search by claim, plate, name or code; status filters; the
   total before ITBIS. Type a claim that does not exist → **Buscar el
   siniestro en todo el historial** → "Ningún servicio con ese número de
   siniestro".
7. Open a tow → **Cancelar servicio** → reason → "Servicio cancelado"; the
   price card says "No se factura" (cancelled before a truck was on its way).
8. **Cambiar contraseña**: wrong repeat → "Las contraseñas no coinciden";
   a short one → "Usa al menos 8 caracteres"; a good one
   (`Titan2026seguro`) → "Contraseña actualizada".

**As the manager**
1. The sidebar also has **Facturas** and **Usuarios**.
2. **Usuarios**: the operator has a role menu and an on/off switch; your own
   row says "Tú" with no controls. Deactivate the operator, then sign in as
   them → "Sin acceso al portal … desactivado". Reactivate them.
3. **Facturas**: empty until the office issues one. Generate an invoice as the
   office, then look again as the manager → the invoice is listed with "Por
   pagar"; open it → print and Excel work, and there are no pay/void
   buttons.

**Suspended company:** as the office, suspend the company with a reason, then
sign in as the operator → "Sin acceso al portal" with that reason and a
sign-out button. Reactivate it.

### 2.3 Driver app

Run it on a phone, or in Chrome on port 50166, and sign in with the chofer
account. The app puts you online by itself; there is no switch. Nothing
arrives until somebody orders a tow near you.

**A. An insurance company's tow**
1. As the portal operator, order a tow with its pickup near the chofer.
2. The offer shows "Ganancia por este servicio · Aseguradora". Accept it.
3. On the job screen check:
   - the insurer banner: company name, "Siniestro …", the insured's name, a
     **call the insured** button, and no chat or call buttons for a customer;
   - "Ganancia por este servicio" with the chofer's share of the zone price;
   - the notice that the insurer pays: do not charge the customer.
4. At the pickup, **LLEGUÉ**. From far away it says "Estás a … km".
5. **INICIAR SERVICIO** opens **Fotos antes de cargar**. The button stays off
   until you take at least one photo; the photos come from the camera only
   (up to 6), and a photo can be removed before sending. **Todavía no**
   leaves the job as it was.
6. At the destination, **FINALIZAR SERVICIO** opens **Fotos al entregar**, the
   same way. If the server refuses because you are not at the destination,
   pressing FINALIZAR again sends the same photos without asking for new ones.
7. The job closes by itself, with no cash step. **Mis ganancias → Mi
   balance** shows the share under "Esta semana hasta ahora".

**B. A customer's cash tow (for comparison)**
1. Request a tow from the client app (2.4) near the chofer.
2. The job screen shows the cash total, not an insurer banner.
3. LLEGUÉ → INICIAR (photos) → FINALIZAR (photos) → **COBRADO EN EFECTIVO
   RD$…** → confirm.
4. In **Mi balance**, "Esta semana hasta ahora" goes down by that job's
   commission.

**C. Other checks**
- **Perfil → Cerrar sesión**: you go offline and no new requests arrive.
- **Mis ganancias** → **Ver mis cortes** opens the Mis cortes screen; after the
  office generates cortes (2.1.D), the corte is listed there.
- On a narrow phone size (Chrome dev tools, 360 px wide) the balance chip and
  the cards fit without overflow.

### 2.4 Client app (quick check only)

Sign in with a number registered under Authentication → Phone → "Phone
numbers for testing" and its fixed code (a debug build run with
`--dart-define=DISABLE_APP_VERIFICATION=true`). Request a tow, check the
price, let a truck be assigned, cancel it, and open your history. Everything
should work as in v1. Nothing in this app changed for Phase 2.

## 3. End to end on Firebase (after deploying)

Once deployed (see [fase2_despliegue.md](fase2_despliegue.md)), repeat the
flow against the real project:

```bash
flutter run -d chrome --dart-define-from-file=../../config/dev.json
```

1. **Office (admin_web):** create a test insurer and its manager; note the
   temporary password.
2. **Portal (admin_web, another browser or incognito):** sign in as that
   manager → forced to **Cambiar contraseña** → then the portal. Order a tow
   near an online test driver.
3. **Driver app (phone or Chrome):** the offer shows "Ganancia por este
   servicio · Aseguradora". Accept → LLEGUÉ (at the pickup) → INICIAR (photos)
   → FINALIZAR → it closes with nothing to collect.
4. **Portal:** the tow shows "Completado/Cerrado"; Inicio counts it with its
   cost + ITBIS; the live map followed the truck while it was moving.
5. **Office:** in Servicios the tow says "Por facturar a la aseguradora".
   **Facturación → Generar facturas** (current month, that company) →
   `B0100000001`, test badge; print and Excel.
6. **Portal as the manager:** **Facturas** shows the invoice.
7. **Office → Cortes → Generar cortes ahora:** the driver's corte includes
   the 70% share. **Driver app → Mis cortes** shows it the same way; after
   **Registrar transferencia al chofer** in the office, the driver's balance
   says "Estás al día".
8. **Cash conflict check:** for a driver with a cash job, generate the weekly
   corte first, then open **Efectivo** for that driver: that job is no longer
   listed to receive.
9. Clean up: void the test invoice and corte, deactivate the test insurer.

Before step 7, set `config/settlements.startAt` (see the deploy notes), or the
first corte will include the driver's old v1 jobs.
