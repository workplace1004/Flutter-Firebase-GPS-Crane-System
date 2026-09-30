# Fase 2 — Módulo de aseguradoras: notas de despliegue

Lo que hace falta para poner en producción la Fase 2 sobre la v1 que ya corre en
el proyecto `gruasrd-ce2ae`, en el orden en que hay que hacerlo, y cómo
comprobar que quedó bien.

## Qué trae la Fase 2

| Parte | Qué es |
|---|---|
| Portal de aseguradoras | Un rol nuevo (`insurer`) dentro del panel web: inicio con números del mes, crear servicio con precio por zona, mapa en vivo, historial, facturas (solo administradores de la aseguradora) y usuarios. |
| Tarifa por zonas | Tabla base (0–10, 10–25, 25–50, +50 km × ligero / SUV / pesado) y tarifa propia por aseguradora. ITBIS 18 % al final de la factura. |
| Pago al chofer | 70 % del precio de la zona en servicios de aseguradora (configurable por aseguradora); 80 % en servicios privados. |
| Corte semanal | Cada viernes a las 8:00: lo que Titan le debe al chofer por aseguradoras menos la comisión de sus servicios en efectivo. Lo ven el chofer y la oficina. |
| Factura mensual con NCF | El día 1 a las 6:00, una factura de crédito fiscal (B01) por aseguradora. Mientras no haya secuencia real, NCF de prueba marcados `isTestNcf`. Imprimible y exportable a Excel. |
| Balance del chofer | En la app del chofer: cortes pendientes más la semana en curso. |

## Antes de empezar

- Plan Blaze (las tareas programadas usan Cloud Scheduler).
- `firebase-tools` con sesión iniciada en una cuenta con permiso de despliegue.
- Node 20 y Flutter del proyecto (`flutter pub get` en la raíz).
- El secreto `QUOTE_SIGNING_SECRET` ya existe desde la v1. Las funciones nuevas de
  aseguradoras lo usan también; no hay que crear otro. Compruébalo:

  ```bash
  firebase functions:secrets:access QUOTE_SIGNING_SECRET
  ```

- El secreto `MAPS_API_KEY`, si quieres que las rutas se dibujen por las calles
  y no en línea recta. Ver "Rutas por calle" más abajo.

- Todas las pruebas en verde (ver "Pruebas" al final).

## Rutas por calle

El servidor calcula la ruta **una sola vez**, cuando se crea el servicio, y la
guarda en el documento (`route.polyline`). Todas las pantallas —cliente, chofer
y panel— dibujan esa misma línea. Sin ella cada una cae en la recta entre los
dos puntos, que el panel dibuja **punteada** y con el aviso "Ruta aproximada, no
por calles": la distancia que se muestra también es una estimación (la recta
× 1.35), no el camino real.

Para que haya ruta real hacen falta dos cosas, en dos llaves distintas:

| Dónde | Llave | API que hay que habilitar |
|---|---|---|
| Servidor (funciones) | Secreto `MAPS_API_KEY` | **Routes API** |
| Navegador (`apps/admin_web/web/index.html`) | La llave del `<script>` de Maps | **Maps JavaScript API** y **Directions API** |

```bash
firebase functions:secrets:set MAPS_API_KEY
firebase deploy --only functions
```

La llave del servidor no es la misma que la del navegador: aquélla se restringe
a la Routes API, ésta por referente HTTP. La del navegador solo se usa como
respaldo, para servicios ya creados sin ruta guardada; si le falta la Directions
API, el panel se queda en la recta punteada aunque el mapa se vea bien.

Los servicios creados **antes** de poner el secreto no tienen ruta guardada y
seguirán mostrándose punteados: la ruta se calcula al crearlos, no al abrirlos.

## Orden de despliegue

Hazlo en este orden: los índices tardan en construirse y las funciones nuevas
los necesitan desde la primera consulta.

### 1. Índices de Firestore

```bash
firebase deploy --only firestore:indexes
```

Espera a que todos digan **Habilitado** en la consola (Firestore → Índices).
Los nuevos son:

| Colección | Campos | Para qué |
|---|---|---|
| `services` | `insurerId` ↑, `insurance.claimKey` ↑, `status` ↑ | No pedir dos grúas para el mismo siniestro |
| `services` | `insurerId` ↑, `createdAt` ↓ | Historial y números del portal |
| `insurerInvoices` | `insurerId` ↑, `createdAt` ↓ | Facturas de una aseguradora |
| `driverSettlements` | `driverId` ↑, `createdAt` ↓ | Cortes de un chofer |
| `driverSettlements` | `status` ↑, `createdAt` ↓ | Cortes pendientes en la oficina |
| `entries` (subcolección de `earnings`) | `settled` ↑, `completedAt` ↑ | El corte semanal, en orden y desde la fecha de inicio |

### 2. Reglas

```bash
firebase deploy --only firestore:rules,storage
```

Las reglas de Storage ahora consultan Firestore (solo el chofer asignado puede
subir fotos a `service_photos/{servicio}`). La primera vez, la CLI pide
**conceder a Storage permiso para leer Firestore**: acepta. Sin ese permiso
toda subida a esa carpeta queda rechazada.

### 3. Funciones

```bash
firebase deploy --only functions
```

El `predeploy` compila TypeScript. Funciones nuevas:

| Función | Tipo | Quién |
|---|---|---|
| `createInsurer`, `updateInsurer` | llamada | admin |
| `createInsurerUser`, `updateInsurerUser` | llamada | admin, o administrador de la aseguradora |
| `insurerPasswordChanged` | llamada | usuario de aseguradora |
| `quoteInsurerService`, `createInsurerService` | llamada | usuario de aseguradora activo |
| `savePricingTable`, `resetPricingTable` | llamada | admin |
| `generateDriverSettlements`, `settleDriverSettlement`, `voidDriverSettlement` | llamada | admin |
| `generateInsurerInvoices`, `markInsurerInvoicePaid`, `voidInsurerInvoice` | llamada | admin |
| `saveFiscalIssuer`, `saveNcfSequence` | llamada | admin |
| `weeklyDriverSettlements` | programada | viernes 8:00 (hora de Santo Domingo) |
| `monthlyInsurerInvoices` | programada | día 1, 6:00 |
| `closeFinishedInsurerTows` | programada | cada 5 minutos |

Funciones de la v1 que cambian: `completeService`, `cancelService`,
`confirmCashCollected`, `settleDriverCash`, `recordEarnings`, el despacho (la
oferta lleva la ganancia del chofer), `setAdminRole`, `whoAmI`, `ensureProfile` y
`startCall` (no llama a un cliente que no existe en un servicio de aseguradora).

Si la CLI pregunta si borrar funciones que ya no están en el código, **no**
aceptes sin revisar la lista: la Fase 2 no elimina ninguna.

### 4. Panel web

**Vuelve a compilar antes de publicar**: la carpeta `apps/admin_web/build/web`
puede tener una compilación vieja.

```bash
cd apps/admin_web
flutter build web --release
cd ../..
firebase deploy --only hosting
```

Abre el panel publicado y confirma que el inicio de sesión pide una cuenta real
y rechaza una contraseña equivocada.

### 5. App del chofer

Nueva versión con el balance, los cortes y la ganancia por servicio. Súbela a
las tiendas como de costumbre. Las versiones anteriores siguen funcionando,
pero no muestran nada de la Fase 2.

La app del cliente no cambia.

## Configuración después del despliegue

### Fecha de inicio de los cortes (obligatorio)

Los choferes tienen servicios de la v1 que nunca pasaron por un corte semanal.
Para que el primer corte no los cobre, en Firestore crea el documento
`config/settlements` con:

| Campo | Tipo | Valor |
|---|---|---|
| `startAt` | timestamp | la fecha y hora en que empiezan los cortes (por ejemplo, el lunes de la primera semana) |

Todo servicio terminado antes de esa fecha queda fuera de los cortes y del
balance del chofer.

### Efectivo de la v1 y el corte semanal

La pantalla **Efectivo → Recibir** (la oficina recibe el efectivo del chofer)
sigue existiendo. Los dos sistemas ya no se pisan:

- Un servicio en efectivo que un corte semanal ya cobró (el chofer se quedó con
  el dinero y pagó el 20 %) no aparece para recibir en la oficina.
- Un servicio cuyo efectivo recibió la oficina no se vuelve a cobrar en el
  corte del viernes.

Con la opción A (el chofer se queda el efectivo y paga el 20 % cada viernes),
la oficina no necesita usar **Efectivo → Recibir**. Decidan si la retiran.

### Datos fiscales y NCF

En el panel: **Facturación → Comprobantes (NCF)**.

1. **Ahora (en constitución):** escribe la razón social; deja el RNC vacío. Las
   facturas dicen "RNC: En trámite" y usan NCF de prueba `B0100000001`,
   `B0100000002`… con la marca "COMPROBANTE DE PRUEBA — SIN VALOR FISCAL".
2. **Cuando llegue el RNC:** escríbelo en la misma pantalla y guarda.
3. **Cuando la DGII autorice la secuencia:** en "Registrar secuencia
   autorizada" escribe *Desde*, *Hasta* y la *Fecha de vencimiento* y confirma.
   La siguiente factura sale con NCF real. No hay que tocar código.
4. **Facturas de prueba ya emitidas:** siguen marcadas como prueba. Si deben
   salir con NCF real, anúlalas (el servicio vuelve a "por facturar") y genera
   las facturas de nuevo.

El sistema nunca emite dos veces el mismo NCF real, avisa cuando quedan 20 o
menos y cuando la secuencia vence en 30 días, y deja de facturar (con el
motivo) si se agota o vence.

**Pendiente con el contador:** los NCF reales anulados deben reportarse en el
formato 608, y una factura ya cobrada solo se corrige con una nota de crédito
(B04). Ninguna de las dos cosas se genera todavía.

### Tarifa base

En **Aseguradoras → Tarifa base** confirma los precios (vienen con la tabla
acordada). Cada aseguradora puede tener precio propio en su pestaña **Tarifa**.

### Aseguradoras y sus usuarios

**Aseguradoras → Nueva aseguradora** (RNC válido de empresa, correo de
facturación, porcentaje del chofer si no es 70 %). Luego, en **Usuarios**, crea
el primer administrador: el sistema muestra una contraseña temporal una sola
vez; al entrar, el portal obliga a cambiarla.

## Comprobación después del despliegue

1. Entra al panel con una cuenta de oficina: aparecen **Aseguradoras**,
   **Cortes** y **Facturación**.
2. Crea una aseguradora de prueba y su administrador. Entra con esa cuenta en
   otra ventana: pide cambiar la contraseña y luego muestra el portal, sin
   ninguna página de la oficina.
3. Pide una grúa de prueba desde el portal: ves el precio antes de confirmar;
   un chofer recibe la oferta con "Ganancia por este servicio".
4. Completa el servicio desde la app del chofer: se cierra solo, sin cobro en
   efectivo; en Servicios figura "Por facturar a la aseguradora".
5. **Facturación → Generar facturas**, mes en curso, esa aseguradora: sale con
   `B0100000001` marcada de prueba. Imprímela y expórtala a Excel.
6. **Cortes → Generar cortes ahora**: el chofer ve el corte y su balance.
7. Anula la factura y el corte de prueba, y desactiva la aseguradora de prueba.

## Tareas programadas

| Función | Horario (Santo Domingo) | Hace | Si falla |
|---|---|---|---|
| `weeklyDriverSettlements` | viernes 8:00 | Cortes de todos los choferes (incluye archivados con saldo) | La oficina los genera a mano; avisa a los administradores |
| `monthlyInsurerInvoices` | día 1, 6:00 | Facturas del mes anterior | Aviso a los administradores con el motivo (p. ej. secuencia agotada) |
| `closeFinishedInsurerTows` | cada 5 min | Cierra servicios de aseguradora que quedaron en "completado" | Se registra en los logs |

## Si hay que volver atrás

- **Funciones:** vuelve a desplegar el commit anterior
  (`git checkout 056066b -- functions && firebase deploy --only functions`).
  Las funciones nuevas quedan sin usar; bórralas desde la consola si hace falta.
- **Reglas:** despliega las del commit anterior. Las colecciones nuevas
  (`insurers`, `pricingRules`, `driverSettlements`, `insurerInvoices`,
  `fiscal`, `ncfRegistry`) quedan cerradas por la regla final "todo lo demás
  denegado".
- **Datos:** la Fase 2 no modifica documentos de la v1 salvo el campo
  `payment.weeklySettlementId` en servicios en efectivo cobrados por un corte y
  los campos `settled`/`settlementId` de las ganancias. Nada se borra.
- **No** borres `ncfRegistry` ni `fiscal/ncf_B01`: son el registro de los NCF
  emitidos.

## Pruebas

```bash
# Dart: en cada paquete
cd packages/grua_core && flutter analyze && flutter test
cd apps/admin_web     && flutter analyze && flutter test
cd apps/driver_app    && flutter analyze && flutter test
cd apps/client_app    && flutter analyze && flutter test

# Funciones (necesita Java 21 para los emuladores)
cd functions
npx tsc --noEmit -p .
npm run lint
npm run test:emulator
```

`npm run test:emulator` levanta Firestore, Realtime Database, Auth y Storage.

## Decisiones a confirmar con Titan

- El límite de 10 km cobra la zona 0–10 (RD$2,500); 10.1 km ya es 10–25.
- La camioneta se cobra como SUV.
- Los kilómetros se miden en décimas.
- Los recargos (nocturno +25 %, domingo/feriado +15 %) no están activos en la
  tarifa de aseguradoras.
- La comisión de los servicios privados se calcula sobre el total cobrado.
- El cargo por cancelación tardía de una aseguradora es el mismo de los
  clientes (RD$500), se suma a su factura con ITBIS, y el chofer no recibe
  parte.
- Retirar o no **Efectivo → Recibir** (ver arriba).
