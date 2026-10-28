-- Copyright 2026 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- ============================================================================
-- Sample supply chain and inventory dataset: "Summit Trail Supply"
-- A wholesale distributor of outdoor gear: 3 distribution centers, 40 SKUs,
-- 12 suppliers, 80 retail customers, and ~9 months of daily transactions
-- (2025-11-03 through 2026-07-31) with weekly (Sunday) inventory snapshots.
--
-- Written to match what an ERP/WMS extract contains, including planning
-- parameters and cycle counts that can differ from system on-hand records.
--
-- Fill-rate conventions (derivable from sales_order_lines, not precomputed):
--   unit  fill = SUM(qty_shipped) / SUM(qty_ordered)
--   line  fill = COUNT(lines shipped complete) / COUNT(lines)
--   order fill = COUNT(orders with every line complete) / COUNT(orders)
-- A shortfall on a line (qty_shipped < qty_ordered) is a CUT: the remainder
-- did not ship later (standard wholesale first-shipment convention).
-- ============================================================================

-- End the implicit transaction started by `gcloud alloydb clusters import --sql`
-- (`psql --single-transaction`) so CREATE DATABASE can execute, then connect.
COMMIT;
SELECT 'CREATE DATABASE inventory_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'inventory_db')\gexec
\connect inventory_db

BEGIN;

DROP TABLE IF EXISTS
    cycle_counts,
    demand_forecasts,
    inventory_snapshots,
    purchase_order_lines,
    purchase_orders,
    sales_order_lines,
    sales_orders,
    customers,
    products,
    suppliers,
    distribution_centers
CASCADE;

CREATE TABLE distribution_centers (
    dc_id       int PRIMARY KEY,
    code        text NOT NULL UNIQUE,        -- e.g. 'RNO'
    name        text NOT NULL,
    city        text NOT NULL,
    state       text NOT NULL
);
COMMENT ON TABLE distribution_centers IS
    'The three DCs orders ship from and inventory is held at.';

CREATE TABLE suppliers (
    supplier_id int PRIMARY KEY,
    name        text NOT NULL,
    city        text NOT NULL,
    state       text NOT NULL
);
COMMENT ON TABLE suppliers IS
    'Vendors replenishment purchase orders are placed with.';

CREATE TABLE products (
    product_id     int PRIMARY KEY,
    sku            text NOT NULL UNIQUE,
    name           text NOT NULL,
    category       text NOT NULL,
    supplier_id    int NOT NULL REFERENCES suppliers,
    case_pack      int NOT NULL,             -- units per case; orders are case multiples
    unit_cost      numeric(10,2) NOT NULL,
    list_price     numeric(10,2) NOT NULL,
    lead_time_days int NOT NULL,             -- PLANNED replenishment lead time (master data)
    reorder_point  int NOT NULL,             -- reorder triggers when system on-hand + on-order <= this
    safety_stock   int NOT NULL              -- planning buffer embedded in reorder_point
);
COMMENT ON TABLE products IS
    'Item master. lead_time_days / reorder_point / safety_stock are the '
    'PLANNING PARAMETERS the replenishment system uses — they reflect what '
    'planners configured, which is not necessarily what suppliers deliver.';

CREATE TABLE customers (
    customer_id int PRIMARY KEY,
    name        text NOT NULL,
    segment     text NOT NULL,               -- 'independent' | 'regional_chain' | 'online'
    city        text NOT NULL,
    state       text NOT NULL
);
COMMENT ON TABLE customers IS 'Retailers who buy wholesale from Summit Trail Supply.';

CREATE TABLE sales_orders (
    order_id          int PRIMARY KEY,
    customer_id       int NOT NULL REFERENCES customers,
    dc_id             int NOT NULL REFERENCES distribution_centers,
    order_date        date NOT NULL,
    promised_ship_date date NOT NULL,        -- service promise made at order entry
    status            text NOT NULL          -- 'shipped' | 'partial' | 'cut'
);
COMMENT ON TABLE sales_orders IS
    'Customer order headers. status: shipped = every line complete, '
    'partial = some quantity shipped, cut = nothing shipped.';

CREATE TABLE sales_order_lines (
    order_line_id int PRIMARY KEY,
    order_id      int NOT NULL REFERENCES sales_orders,
    product_id    int NOT NULL REFERENCES products,
    qty_ordered   int NOT NULL,
    qty_shipped   int NOT NULL,              -- may be < qty_ordered (cut) or 0
    unit_price    numeric(10,2) NOT NULL,
    ship_date     date                       -- NULL when nothing shipped
);
COMMENT ON TABLE sales_order_lines IS
    'Order lines: the fill-rate ground truth. qty_shipped < qty_ordered is a '
    'cut line — the unshipped remainder was NOT fulfilled later.';

CREATE TABLE purchase_orders (
    po_id       int PRIMARY KEY,
    supplier_id int NOT NULL REFERENCES suppliers,
    dc_id       int NOT NULL REFERENCES distribution_centers,
    order_date  date NOT NULL,
    promised_date date NOT NULL,             -- order_date + product lead_time_days
    status      text NOT NULL                -- 'open' | 'received' | 'partial'
);
COMMENT ON TABLE purchase_orders IS
    'Replenishment PO headers. promised_date is derived from the item '
    'master''s planned lead time at order time.';

CREATE TABLE purchase_order_lines (
    po_line_id    int PRIMARY KEY,
    po_id         int NOT NULL REFERENCES purchase_orders,
    product_id    int NOT NULL REFERENCES products,
    qty_ordered   int NOT NULL,
    qty_received  int NOT NULL,              -- 0 while open; may be < qty_ordered
    received_date date                       -- actual goods receipt; NULL while open
);
COMMENT ON TABLE purchase_order_lines IS
    'PO lines with promised-vs-actual receipt evidence: compare '
    'received_date to the header''s promised_date, qty_received to qty_ordered.';

CREATE TABLE inventory_snapshots (
    snapshot_date date NOT NULL,
    product_id    int NOT NULL REFERENCES products,
    dc_id         int NOT NULL REFERENCES distribution_centers,
    qty_on_hand   int NOT NULL,              -- SYSTEM on-hand (the record''s belief)
    PRIMARY KEY (snapshot_date, product_id, dc_id)
);
COMMENT ON TABLE inventory_snapshots IS
    'Weekly (Sunday) end-of-day SYSTEM on-hand per product per DC — what '
    'the ERP believed, which physical counts may contradict.';

CREATE TABLE demand_forecasts (
    product_id     int NOT NULL REFERENCES products,
    dc_id          int NOT NULL REFERENCES distribution_centers,
    forecast_month date NOT NULL,            -- first of month
    forecast_units int NOT NULL,
    PRIMARY KEY (product_id, dc_id, forecast_month)
);
COMMENT ON TABLE demand_forecasts IS
    'Monthly demand plan per product per DC, produced by the planning team '
    'before each month. Compare with actual demand from sales_order_lines.';

CREATE TABLE cycle_counts (
    count_id    int PRIMARY KEY,
    count_date  date NOT NULL,
    dc_id       int NOT NULL REFERENCES distribution_centers,
    product_id  int NOT NULL REFERENCES products,
    system_qty  int NOT NULL,                -- what the system said at count time
    counted_qty int NOT NULL                 -- what was physically on the shelf
);
COMMENT ON TABLE cycle_counts IS
    'Physical inventory counts. counted_qty vs system_qty exposes inventory '
    'record inaccuracy; count DATES expose gaps in count discipline.';

-- Indexes for the analytic access paths the investigation uses.
CREATE INDEX ON sales_orders (order_date);
CREATE INDEX ON sales_orders (dc_id, order_date);
CREATE INDEX ON sales_order_lines (order_id);
CREATE INDEX ON sales_order_lines (product_id);
CREATE INDEX ON purchase_orders (supplier_id, order_date);
CREATE INDEX ON purchase_order_lines (po_id);
CREATE INDEX ON purchase_order_lines (product_id);
CREATE INDEX ON inventory_snapshots (product_id, dc_id, snapshot_date);
CREATE INDEX ON cycle_counts (dc_id, count_date);


COPY distribution_centers (dc_id, code, name, city, state) FROM stdin;
1	RNO	Reno Distribution Center	Reno	NV
2	CMH	Columbus Distribution Center	Columbus	OH
3	DFW	Fort Worth Distribution Center	Fort Worth	TX
\.
COPY suppliers (supplier_id, name, city, state) FROM stdin;
1	Cascade Ridge Manufacturing	Bend	OR
2	Pacific Trail Imports	Tacoma	WA
3	Ironwood Fabrication	Boise	ID
4	Bluewater Textiles	Charlotte	NC
5	Northstar Alloy Works	Duluth	MN
6	Redwood Plastics Co	Eureka	CA
7	Keystone Gear Labs	Allentown	PA
8	Summit Forge Industries	Golden	CO
9	Lakeshore Composites	Traverse City	MI
10	Highline Optics	Ogden	UT
11	Granite Peak Tooling	Barre	VT
12	Silver Creek Webbing	Chattanooga	TN
\.
COPY products (product_id, sku, name, category, supplier_id, case_pack, unit_cost, list_price, lead_time_days, reorder_point, safety_stock) FROM stdin;
1	STS-0001	Stonefly Water Bottle Pro	Hydration & Coolers	6	6	6.13	12.49	10	42	25
2	STS-0002	Cirque Hydration Pack 45qt	Hydration & Coolers	8	6	49.75	104.33	28	133	55
3	STS-0003	Talus Cooler Pro	Hydration & Coolers	6	12	11.69	26.74	14	97	56
4	STS-0004	Stonefly Insulated Jug 45qt	Hydration & Coolers	8	12	19.36	37.77	10	128	68
5	STS-0005	Cirque Flask Pro	Hydration & Coolers	6	24	59.8	111.03	14	268	140
6	STS-0006	Northfork Dome Tent Lite	Tents & Shelters	1	24	67.34	154.57	14	324	159
7	STS-0007	Basin Backpacking Tent	Tents & Shelters	1	6	71.64	159.96	14	35	22
8	STS-0008	Juniper Tarp Shelter Lite	Tents & Shelters	1	6	27.15	49.81	21	74	37
9	STS-0009	Northfork Bivy	Tents & Shelters	1	24	59.75	129.89	10	254	135
10	STS-0010	Basin Canopy Lite	Tents & Shelters	1	24	35.91	74.91	10	109	73
11	STS-0011	Meridian Sleeping Bag 20L	Sleeping Bags & Pads	4	6	86.66	195.04	14	40	24
12	STS-0012	Ridgeline Sleeping Pad 2P	Sleeping Bags & Pads	9	24	83.73	145.58	10	334	162
13	STS-0013	Kestrel Camp Quilt 20L	Sleeping Bags & Pads	4	12	55.03	97.54	28	170	82
14	STS-0014	Meridian Air Mattress 2P	Sleeping Bags & Pads	9	12	68.14	116.19	21	95	55
15	STS-0015	Ridgeline Liner 20L	Sleeping Bags & Pads	4	12	76.8	170.21	21	162	79
16	STS-0016	Timberline Daypack 35L	Backpacks & Bags	12	12	86.17	161.56	21	333	126
17	STS-0017	Alpine Trekking Pack 3P	Backpacks & Bags	4	6	23.66	53.01	10	47	27
18	STS-0018	Wildwood Duffel 35L	Backpacks & Bags	12	24	39.12	82.83	28	363	171
19	STS-0019	Timberline Hip Pack 3P	Backpacks & Bags	4	24	68.96	153.58	14	160	98
20	STS-0020	Alpine Dry Bag 35L	Backpacks & Bags	12	6	39.13	68.61	28	114	50
21	STS-0021	Cirque Camp Stove 60L	Camp Kitchen	2	24	34.29	59.84	7	135	86
22	STS-0022	Talus Cook Set XL	Camp Kitchen	7	6	72.84	165.43	14	59	32
23	STS-0023	Stonefly French Press 60L	Camp Kitchen	2	12	22.74	46.91	7	82	50
24	STS-0024	Cirque Utensil Kit XL	Camp Kitchen	7	24	18.38	36.72	14	284	146
25	STS-0025	Talus Grill 60L	Camp Kitchen	2	6	86.3	171.1	7	47	27
26	STS-0026	Basin Headlamp 1L	Lighting & Electronics	10	6	30.24	55.53	28	182	66
27	STS-0027	Juniper Lantern Compact	Lighting & Electronics	5	12	10.09	17.24	10	120	65
28	STS-0028	Northfork Flashlight 1L	Lighting & Electronics	10	12	81.28	176.24	14	72	45
29	STS-0029	Basin Power Bank Compact	Lighting & Electronics	5	6	27.55	47.33	28	126	53
30	STS-0030	Juniper Solar Charger 1L	Lighting & Electronics	10	24	83.81	184.29	21	376	175
31	STS-0031	Ridgeline Trekking Poles 45qt	Trekking & Climbing	5	24	84.17	150.44	28	817	285
32	STS-0032	Kestrel Carabiner Set Pro	Trekking & Climbing	11	6	65.62	124.18	14	34	22
33	STS-0033	Meridian Climbing Harness 45qt	Trekking & Climbing	5	6	59.41	117.28	14	77	38
34	STS-0034	Ridgeline Crampons Pro	Trekking & Climbing	11	12	63.45	134.91	14	56	38
35	STS-0035	Kestrel Rope Bag 45qt	Trekking & Climbing	5	12	63.79	125.1	10	62	41
36	STS-0036	Alpine Rain Shell	Rainwear & Accessories	3	24	63.47	119.54	14	144	90
37	STS-0037	Wildwood Poncho Lite	Rainwear & Accessories	4	24	56.36	129.57	10	393	180
38	STS-0038	Timberline Gaiters	Rainwear & Accessories	3	12	72.02	155.44	14	181	85
39	STS-0039	Alpine Pack Cover Lite	Rainwear & Accessories	4	6	14.15	32.52	14	87	42
40	STS-0040	Wildwood Camp Towel	Rainwear & Accessories	3	6	18.1	38.67	21	60	33
\.
COPY customers (customer_id, name, segment, city, state) FROM stdin;
1	Boulder Outdoor Supply	regional_chain	Boulder	CO
2	Summit Shop Bozeman	regional_chain	Bozeman	MT
3	Asheville Outdoor Supply	regional_chain	Asheville	NC
4	Summit Shop Bend	independent	Bend	OR
5	Flagstaff Outdoor Supply	independent	Flagstaff	AZ
6	Summit Shop Burlington	independent	Burlington	VT
7	Missoula Outdoor Supply	independent	Missoula	MT
8	Summit Shop Santa Fe	online	Santa Fe	NM
9	Duluth Outdoor Supply	independent	Duluth	MN
10	Summit Shop Ithaca	online	Ithaca	NY
11	Moab Outdoor Supply	independent	Moab	UT
12	Summit Shop Chattanooga	independent	Chattanooga	TN
13	Spokane Outdoor Supply	independent	Spokane	WA
14	Summit Shop Madison	regional_chain	Madison	WI
15	Knoxville Outdoor Supply	independent	Knoxville	TN
16	Summit Shop Eugene	independent	Eugene	OR
17	Fort Collins Outdoor Supply	regional_chain	Fort Collins	CO
18	Summit Shop Ann Arbor	independent	Ann Arbor	MI
19	Boise Outdoor Supply	independent	Boise	ID
20	Summit Shop Asheville	independent	Asheville	NC
21	Boulder Outdoor Supply #21	independent	Boulder	CO
22	Summit Shop Bozeman #22	independent	Bozeman	MT
23	Asheville Outdoor Supply #23	regional_chain	Asheville	NC
24	Summit Shop Bend #24	independent	Bend	OR
25	Flagstaff Outdoor Supply #25	independent	Flagstaff	AZ
26	Summit Shop Burlington #26	online	Burlington	VT
27	Missoula Outdoor Supply #27	independent	Missoula	MT
28	Summit Shop Santa Fe #28	regional_chain	Santa Fe	NM
29	Duluth Outdoor Supply #29	independent	Duluth	MN
30	Summit Shop Ithaca #30	online	Ithaca	NY
31	Moab Outdoor Supply #31	regional_chain	Moab	UT
32	Summit Shop Chattanooga #32	independent	Chattanooga	TN
33	Spokane Outdoor Supply #33	regional_chain	Spokane	WA
34	Summit Shop Madison #34	online	Madison	WI
35	Knoxville Outdoor Supply #35	online	Knoxville	TN
36	Summit Shop Eugene #36	independent	Eugene	OR
37	Fort Collins Outdoor Supply #37	independent	Fort Collins	CO
38	Summit Shop Ann Arbor #38	independent	Ann Arbor	MI
39	Boise Outdoor Supply #39	regional_chain	Boise	ID
40	Summit Shop Asheville #40	independent	Asheville	NC
41	Boulder Outdoor Supply #41	independent	Boulder	CO
42	Summit Shop Bozeman #42	independent	Bozeman	MT
43	Asheville Outdoor Supply #43	regional_chain	Asheville	NC
44	Summit Shop Bend #44	independent	Bend	OR
45	Flagstaff Outdoor Supply #45	independent	Flagstaff	AZ
46	Summit Shop Burlington #46	independent	Burlington	VT
47	Missoula Outdoor Supply #47	online	Missoula	MT
48	Summit Shop Santa Fe #48	regional_chain	Santa Fe	NM
49	Duluth Outdoor Supply #49	regional_chain	Duluth	MN
50	Summit Shop Ithaca #50	regional_chain	Ithaca	NY
51	Moab Outdoor Supply #51	independent	Moab	UT
52	Summit Shop Chattanooga #52	independent	Chattanooga	TN
53	Spokane Outdoor Supply #53	independent	Spokane	WA
54	Summit Shop Madison #54	online	Madison	WI
55	Knoxville Outdoor Supply #55	independent	Knoxville	TN
56	Summit Shop Eugene #56	online	Eugene	OR
57	Fort Collins Outdoor Supply #57	independent	Fort Collins	CO
58	Summit Shop Ann Arbor #58	regional_chain	Ann Arbor	MI
59	Boise Outdoor Supply #59	independent	Boise	ID
60	Summit Shop Asheville #60	independent	Asheville	NC
61	Boulder Outdoor Supply #61	independent	Boulder	CO
62	Summit Shop Bozeman #62	independent	Bozeman	MT
63	Asheville Outdoor Supply #63	online	Asheville	NC
64	Summit Shop Bend #64	regional_chain	Bend	OR
65	Flagstaff Outdoor Supply #65	regional_chain	Flagstaff	AZ
66	Summit Shop Burlington #66	independent	Burlington	VT
67	Missoula Outdoor Supply #67	online	Missoula	MT
68	Summit Shop Santa Fe #68	online	Santa Fe	NM
69	Duluth Outdoor Supply #69	regional_chain	Duluth	MN
70	Summit Shop Ithaca #70	online	Ithaca	NY
71	Moab Outdoor Supply #71	independent	Moab	UT
72	Summit Shop Chattanooga #72	online	Chattanooga	TN
73	Spokane Outdoor Supply #73	independent	Spokane	WA
74	Summit Shop Madison #74	online	Madison	WI
75	Knoxville Outdoor Supply #75	independent	Knoxville	TN
76	Summit Shop Eugene #76	independent	Eugene	OR
77	Fort Collins Outdoor Supply #77	independent	Fort Collins	CO
78	Summit Shop Ann Arbor #78	independent	Ann Arbor	MI
79	Boise Outdoor Supply #79	independent	Boise	ID
80	Summit Shop Asheville #80	regional_chain	Asheville	NC
\.
COPY sales_orders (order_id, customer_id, dc_id, order_date, promised_ship_date, status) FROM stdin;
1	42	1	2025-11-03	2025-11-05	shipped
2	34	1	2025-11-03	2025-11-05	shipped
3	8	1	2025-11-03	2025-11-05	shipped
4	69	1	2025-11-03	2025-11-05	shipped
5	40	1	2025-11-03	2025-11-05	shipped
6	3	2	2025-11-03	2025-11-05	shipped
7	61	2	2025-11-03	2025-11-05	shipped
8	45	2	2025-11-03	2025-11-05	shipped
9	22	2	2025-11-03	2025-11-05	shipped
10	66	2	2025-11-03	2025-11-05	shipped
11	35	3	2025-11-03	2025-11-05	shipped
12	3	1	2025-11-04	2025-11-06	shipped
13	65	1	2025-11-04	2025-11-06	shipped
14	32	1	2025-11-04	2025-11-06	shipped
15	18	3	2025-11-04	2025-11-06	shipped
16	63	1	2025-11-05	2025-11-07	shipped
17	31	1	2025-11-05	2025-11-07	shipped
18	28	1	2025-11-05	2025-11-07	shipped
19	41	1	2025-11-05	2025-11-07	shipped
20	12	2	2025-11-05	2025-11-07	shipped
21	5	2	2025-11-05	2025-11-07	shipped
22	49	2	2025-11-05	2025-11-07	shipped
23	67	2	2025-11-05	2025-11-07	shipped
24	7	2	2025-11-05	2025-11-07	shipped
25	65	3	2025-11-05	2025-11-07	shipped
26	60	3	2025-11-05	2025-11-07	shipped
27	26	1	2025-11-06	2025-11-08	shipped
28	25	1	2025-11-06	2025-11-08	shipped
29	11	1	2025-11-06	2025-11-08	shipped
30	51	1	2025-11-06	2025-11-08	shipped
31	28	2	2025-11-06	2025-11-08	shipped
32	69	1	2025-11-07	2025-11-09	shipped
33	45	1	2025-11-07	2025-11-09	shipped
34	23	1	2025-11-07	2025-11-09	shipped
35	79	1	2025-11-07	2025-11-09	shipped
36	73	1	2025-11-07	2025-11-09	shipped
37	46	2	2025-11-07	2025-11-09	shipped
38	69	3	2025-11-07	2025-11-09	shipped
39	73	2	2025-11-09	2025-11-11	shipped
40	12	3	2025-11-09	2025-11-11	shipped
41	76	3	2025-11-09	2025-11-11	shipped
42	28	1	2025-11-10	2025-11-12	shipped
43	43	2	2025-11-10	2025-11-12	shipped
44	4	2	2025-11-10	2025-11-12	shipped
45	8	2	2025-11-10	2025-11-12	shipped
46	67	3	2025-11-10	2025-11-12	shipped
47	69	3	2025-11-10	2025-11-12	shipped
48	67	3	2025-11-10	2025-11-12	shipped
49	18	3	2025-11-10	2025-11-12	shipped
50	1	3	2025-11-10	2025-11-12	shipped
51	49	3	2025-11-10	2025-11-12	shipped
52	72	1	2025-11-11	2025-11-13	shipped
53	60	1	2025-11-11	2025-11-13	shipped
54	40	1	2025-11-12	2025-11-14	shipped
55	53	3	2025-11-12	2025-11-14	shipped
56	67	1	2025-11-13	2025-11-15	shipped
57	47	2	2025-11-13	2025-11-15	shipped
58	70	3	2025-11-13	2025-11-15	shipped
59	79	3	2025-11-13	2025-11-15	shipped
60	47	2	2025-11-14	2025-11-16	shipped
61	25	2	2025-11-14	2025-11-16	shipped
62	30	2	2025-11-14	2025-11-16	shipped
63	36	2	2025-11-14	2025-11-16	shipped
64	26	2	2025-11-14	2025-11-16	shipped
65	13	3	2025-11-14	2025-11-16	shipped
66	72	3	2025-11-14	2025-11-16	shipped
67	36	2	2025-11-15	2025-11-17	shipped
68	4	2	2025-11-15	2025-11-17	shipped
69	50	1	2025-11-16	2025-11-18	shipped
70	62	2	2025-11-16	2025-11-18	shipped
71	61	3	2025-11-16	2025-11-18	shipped
72	59	3	2025-11-16	2025-11-18	shipped
73	66	1	2025-11-17	2025-11-19	shipped
74	31	1	2025-11-17	2025-11-19	shipped
75	62	1	2025-11-17	2025-11-19	shipped
76	2	1	2025-11-17	2025-11-19	shipped
77	33	2	2025-11-17	2025-11-19	shipped
78	35	3	2025-11-17	2025-11-19	shipped
79	49	3	2025-11-17	2025-11-19	shipped
80	19	3	2025-11-17	2025-11-19	shipped
81	27	3	2025-11-17	2025-11-19	shipped
82	65	1	2025-11-18	2025-11-20	shipped
83	39	1	2025-11-18	2025-11-20	shipped
84	65	2	2025-11-18	2025-11-20	shipped
85	31	2	2025-11-18	2025-11-20	partial
86	66	2	2025-11-18	2025-11-20	shipped
87	18	3	2025-11-18	2025-11-20	shipped
88	39	3	2025-11-18	2025-11-20	shipped
89	35	3	2025-11-18	2025-11-20	shipped
90	4	1	2025-11-19	2025-11-21	shipped
91	6	1	2025-11-19	2025-11-21	shipped
92	45	2	2025-11-19	2025-11-21	shipped
93	9	2	2025-11-19	2025-11-21	shipped
94	12	2	2025-11-19	2025-11-21	shipped
95	43	1	2025-11-20	2025-11-22	shipped
96	27	1	2025-11-20	2025-11-22	shipped
97	7	2	2025-11-20	2025-11-22	shipped
98	24	2	2025-11-20	2025-11-22	shipped
99	80	2	2025-11-20	2025-11-22	shipped
100	44	2	2025-11-20	2025-11-22	shipped
101	20	3	2025-11-20	2025-11-22	shipped
102	74	3	2025-11-20	2025-11-22	shipped
103	41	3	2025-11-20	2025-11-22	shipped
104	23	1	2025-11-21	2025-11-23	shipped
105	66	1	2025-11-21	2025-11-23	shipped
106	16	1	2025-11-21	2025-11-23	shipped
107	30	1	2025-11-21	2025-11-23	shipped
108	28	2	2025-11-21	2025-11-23	shipped
109	17	2	2025-11-21	2025-11-23	shipped
110	3	2	2025-11-21	2025-11-23	shipped
111	58	2	2025-11-21	2025-11-23	shipped
112	41	3	2025-11-21	2025-11-23	shipped
113	62	3	2025-11-21	2025-11-23	shipped
114	65	3	2025-11-21	2025-11-23	shipped
115	6	1	2025-11-22	2025-11-24	shipped
116	63	1	2025-11-22	2025-11-24	shipped
117	59	3	2025-11-22	2025-11-24	shipped
118	49	1	2025-11-23	2025-11-25	shipped
119	24	1	2025-11-23	2025-11-25	shipped
120	70	1	2025-11-23	2025-11-25	shipped
121	8	2	2025-11-23	2025-11-25	shipped
122	51	3	2025-11-23	2025-11-25	shipped
123	71	1	2025-11-24	2025-11-26	shipped
124	55	1	2025-11-24	2025-11-26	shipped
125	16	1	2025-11-24	2025-11-26	shipped
126	21	1	2025-11-24	2025-11-26	shipped
127	43	1	2025-11-24	2025-11-26	shipped
128	16	2	2025-11-24	2025-11-26	shipped
129	10	2	2025-11-24	2025-11-26	shipped
130	49	3	2025-11-24	2025-11-26	shipped
131	72	3	2025-11-24	2025-11-26	shipped
132	35	1	2025-11-25	2025-11-27	shipped
133	72	1	2025-11-25	2025-11-27	shipped
134	1	1	2025-11-25	2025-11-27	shipped
135	39	2	2025-11-25	2025-11-27	shipped
136	5	2	2025-11-25	2025-11-27	shipped
137	49	2	2025-11-25	2025-11-27	shipped
138	76	3	2025-11-25	2025-11-27	shipped
139	79	3	2025-11-25	2025-11-27	shipped
140	75	3	2025-11-25	2025-11-27	shipped
141	64	1	2025-11-26	2025-11-28	shipped
142	72	1	2025-11-26	2025-11-28	shipped
143	77	2	2025-11-26	2025-11-28	shipped
144	35	2	2025-11-26	2025-11-28	shipped
145	46	2	2025-11-26	2025-11-28	shipped
146	52	3	2025-11-26	2025-11-28	partial
147	49	1	2025-11-27	2025-11-29	partial
148	51	1	2025-11-27	2025-11-29	partial
149	44	2	2025-11-27	2025-11-29	shipped
150	34	1	2025-11-28	2025-11-30	partial
151	10	2	2025-11-28	2025-11-30	shipped
152	45	2	2025-11-28	2025-11-30	shipped
153	42	2	2025-11-28	2025-11-30	shipped
154	77	3	2025-11-28	2025-11-30	shipped
155	10	3	2025-11-28	2025-11-30	shipped
156	10	3	2025-11-28	2025-11-30	shipped
157	42	3	2025-11-28	2025-11-30	shipped
158	32	1	2025-11-29	2025-12-01	shipped
159	60	1	2025-11-29	2025-12-01	shipped
160	60	2	2025-11-29	2025-12-01	shipped
161	59	2	2025-11-29	2025-12-01	shipped
162	20	2	2025-11-29	2025-12-01	shipped
163	59	3	2025-11-29	2025-12-01	shipped
164	73	3	2025-11-29	2025-12-01	shipped
165	68	3	2025-11-29	2025-12-01	shipped
166	60	2	2025-11-30	2025-12-02	shipped
167	40	1	2025-12-01	2025-12-03	shipped
168	75	2	2025-12-01	2025-12-03	shipped
169	53	2	2025-12-01	2025-12-03	shipped
170	36	2	2025-12-01	2025-12-03	partial
171	77	3	2025-12-01	2025-12-03	shipped
172	24	3	2025-12-01	2025-12-03	shipped
173	74	2	2025-12-02	2025-12-04	shipped
174	13	3	2025-12-02	2025-12-04	shipped
175	7	3	2025-12-02	2025-12-04	shipped
176	67	1	2025-12-03	2025-12-05	shipped
177	5	2	2025-12-03	2025-12-05	shipped
178	66	2	2025-12-03	2025-12-05	shipped
179	61	3	2025-12-03	2025-12-05	shipped
180	8	3	2025-12-03	2025-12-05	shipped
181	62	3	2025-12-03	2025-12-05	shipped
182	38	3	2025-12-03	2025-12-05	shipped
183	12	3	2025-12-03	2025-12-05	shipped
184	67	3	2025-12-03	2025-12-05	shipped
185	45	1	2025-12-04	2025-12-06	partial
186	60	1	2025-12-04	2025-12-06	shipped
187	45	1	2025-12-04	2025-12-06	shipped
188	19	1	2025-12-04	2025-12-06	shipped
189	1	2	2025-12-04	2025-12-06	partial
190	69	2	2025-12-04	2025-12-06	shipped
191	46	2	2025-12-04	2025-12-06	shipped
192	18	2	2025-12-04	2025-12-06	shipped
193	73	1	2025-12-05	2025-12-07	shipped
194	29	1	2025-12-05	2025-12-07	shipped
195	48	1	2025-12-05	2025-12-07	shipped
196	67	2	2025-12-05	2025-12-07	partial
197	28	3	2025-12-05	2025-12-07	shipped
198	62	3	2025-12-05	2025-12-07	shipped
199	8	3	2025-12-05	2025-12-07	shipped
200	76	3	2025-12-05	2025-12-07	shipped
201	72	1	2025-12-06	2025-12-08	shipped
202	73	1	2025-12-06	2025-12-08	shipped
203	31	1	2025-12-06	2025-12-08	shipped
204	19	2	2025-12-06	2025-12-08	shipped
205	34	3	2025-12-06	2025-12-08	shipped
206	11	3	2025-12-06	2025-12-08	shipped
207	66	3	2025-12-07	2025-12-09	shipped
208	51	1	2025-12-08	2025-12-10	shipped
209	9	1	2025-12-08	2025-12-10	shipped
210	20	1	2025-12-08	2025-12-10	shipped
211	15	2	2025-12-08	2025-12-10	partial
212	53	2	2025-12-08	2025-12-10	shipped
213	9	2	2025-12-08	2025-12-10	partial
214	53	3	2025-12-08	2025-12-10	shipped
215	18	3	2025-12-08	2025-12-10	shipped
216	11	3	2025-12-08	2025-12-10	partial
217	4	3	2025-12-08	2025-12-10	shipped
218	23	1	2025-12-09	2025-12-11	shipped
219	51	1	2025-12-09	2025-12-11	shipped
220	1	2	2025-12-09	2025-12-11	partial
221	58	2	2025-12-09	2025-12-11	shipped
222	35	2	2025-12-09	2025-12-11	partial
223	75	3	2025-12-09	2025-12-11	shipped
224	21	1	2025-12-10	2025-12-12	shipped
225	51	1	2025-12-10	2025-12-12	shipped
226	51	2	2025-12-10	2025-12-12	shipped
227	74	2	2025-12-10	2025-12-12	shipped
228	72	3	2025-12-10	2025-12-12	shipped
229	26	1	2025-12-11	2025-12-13	shipped
230	53	1	2025-12-11	2025-12-13	shipped
231	47	1	2025-12-11	2025-12-13	shipped
232	9	2	2025-12-11	2025-12-13	shipped
233	31	3	2025-12-11	2025-12-13	partial
234	77	3	2025-12-11	2025-12-13	shipped
235	19	1	2025-12-12	2025-12-14	shipped
236	1	1	2025-12-12	2025-12-14	shipped
237	3	2	2025-12-12	2025-12-14	shipped
238	16	2	2025-12-12	2025-12-14	partial
239	19	2	2025-12-12	2025-12-14	partial
240	41	2	2025-12-12	2025-12-14	shipped
241	79	3	2025-12-12	2025-12-14	partial
242	6	3	2025-12-12	2025-12-14	partial
243	66	3	2025-12-12	2025-12-14	shipped
244	29	3	2025-12-12	2025-12-14	shipped
245	26	3	2025-12-12	2025-12-14	shipped
246	10	1	2025-12-13	2025-12-15	shipped
247	80	1	2025-12-13	2025-12-15	partial
248	59	2	2025-12-13	2025-12-15	shipped
249	76	3	2025-12-13	2025-12-15	partial
250	68	3	2025-12-14	2025-12-16	shipped
251	70	1	2025-12-15	2025-12-17	shipped
252	56	1	2025-12-15	2025-12-17	shipped
253	72	1	2025-12-15	2025-12-17	shipped
254	42	1	2025-12-15	2025-12-17	shipped
255	41	2	2025-12-15	2025-12-17	shipped
256	47	2	2025-12-15	2025-12-17	shipped
257	21	2	2025-12-15	2025-12-17	shipped
258	74	2	2025-12-15	2025-12-17	shipped
259	6	3	2025-12-15	2025-12-17	partial
260	27	3	2025-12-15	2025-12-17	shipped
261	77	1	2025-12-16	2025-12-18	shipped
262	62	1	2025-12-16	2025-12-18	shipped
263	7	1	2025-12-16	2025-12-18	shipped
264	12	1	2025-12-16	2025-12-18	shipped
265	62	1	2025-12-16	2025-12-18	shipped
266	75	2	2025-12-16	2025-12-18	shipped
267	66	2	2025-12-16	2025-12-18	partial
268	16	3	2025-12-16	2025-12-18	shipped
269	22	1	2025-12-17	2025-12-19	partial
270	62	1	2025-12-17	2025-12-19	shipped
271	31	2	2025-12-17	2025-12-19	shipped
272	80	2	2025-12-17	2025-12-19	shipped
273	31	2	2025-12-17	2025-12-19	shipped
274	59	3	2025-12-17	2025-12-19	shipped
275	5	3	2025-12-17	2025-12-19	shipped
276	72	3	2025-12-17	2025-12-19	shipped
277	43	3	2025-12-17	2025-12-19	shipped
278	70	3	2025-12-17	2025-12-19	shipped
279	10	1	2025-12-18	2025-12-20	shipped
280	67	1	2025-12-18	2025-12-20	shipped
281	48	2	2025-12-18	2025-12-20	shipped
282	64	2	2025-12-18	2025-12-20	partial
283	63	3	2025-12-18	2025-12-20	shipped
284	19	3	2025-12-18	2025-12-20	partial
285	38	1	2025-12-19	2025-12-21	shipped
286	75	1	2025-12-19	2025-12-21	shipped
287	35	2	2025-12-19	2025-12-21	shipped
288	61	2	2025-12-19	2025-12-21	shipped
289	56	3	2025-12-19	2025-12-21	shipped
290	14	3	2025-12-19	2025-12-21	shipped
291	34	2	2025-12-20	2025-12-22	shipped
292	27	1	2025-12-21	2025-12-23	shipped
293	40	3	2025-12-21	2025-12-23	partial
294	7	3	2025-12-21	2025-12-23	partial
295	74	1	2025-12-22	2025-12-24	partial
296	60	1	2025-12-22	2025-12-24	shipped
297	73	1	2025-12-22	2025-12-24	shipped
298	78	2	2025-12-22	2025-12-24	partial
299	28	2	2025-12-22	2025-12-24	shipped
300	57	2	2025-12-22	2025-12-24	shipped
301	64	3	2025-12-22	2025-12-24	partial
302	14	3	2025-12-22	2025-12-24	shipped
303	58	3	2025-12-22	2025-12-24	shipped
304	68	1	2025-12-23	2025-12-25	shipped
305	49	1	2025-12-23	2025-12-25	shipped
306	1	1	2025-12-23	2025-12-25	partial
307	13	2	2025-12-23	2025-12-25	shipped
308	19	2	2025-12-23	2025-12-25	shipped
309	34	3	2025-12-23	2025-12-25	shipped
310	45	3	2025-12-23	2025-12-25	shipped
311	80	1	2025-12-24	2025-12-26	shipped
312	53	1	2025-12-24	2025-12-26	shipped
313	10	2	2025-12-24	2025-12-26	shipped
314	9	2	2025-12-24	2025-12-26	shipped
315	11	2	2025-12-24	2025-12-26	shipped
316	80	2	2025-12-24	2025-12-26	shipped
317	70	2	2025-12-24	2025-12-26	partial
318	77	1	2025-12-25	2025-12-27	partial
319	3	1	2025-12-25	2025-12-27	shipped
320	43	2	2025-12-25	2025-12-27	shipped
321	74	2	2025-12-25	2025-12-27	shipped
322	47	2	2025-12-25	2025-12-27	shipped
323	29	3	2025-12-25	2025-12-27	shipped
324	33	3	2025-12-25	2025-12-27	shipped
325	69	3	2025-12-25	2025-12-27	partial
326	40	1	2025-12-26	2025-12-28	shipped
327	67	1	2025-12-26	2025-12-28	shipped
328	36	1	2025-12-26	2025-12-28	shipped
329	9	1	2025-12-26	2025-12-28	shipped
330	10	2	2025-12-26	2025-12-28	shipped
331	60	3	2025-12-26	2025-12-28	shipped
332	65	3	2025-12-26	2025-12-28	shipped
333	10	3	2025-12-26	2025-12-28	shipped
334	77	1	2025-12-27	2025-12-29	shipped
335	17	2	2025-12-27	2025-12-29	shipped
336	50	2	2025-12-27	2025-12-29	shipped
337	42	3	2025-12-27	2025-12-29	shipped
338	61	3	2025-12-27	2025-12-29	partial
339	70	2	2025-12-28	2025-12-30	shipped
340	58	2	2025-12-28	2025-12-30	shipped
341	18	2	2025-12-28	2025-12-30	shipped
342	64	3	2025-12-28	2025-12-30	partial
343	68	2	2025-12-29	2025-12-31	shipped
344	76	2	2025-12-29	2025-12-31	shipped
345	1	2	2025-12-29	2025-12-31	shipped
346	75	2	2025-12-29	2025-12-31	shipped
347	37	3	2025-12-29	2025-12-31	shipped
348	56	3	2025-12-29	2025-12-31	shipped
349	28	1	2025-12-30	2026-01-01	shipped
350	36	2	2025-12-30	2026-01-01	shipped
351	63	2	2025-12-30	2026-01-01	shipped
352	41	3	2025-12-30	2026-01-01	shipped
353	48	3	2025-12-30	2026-01-01	shipped
354	47	3	2025-12-30	2026-01-01	shipped
355	13	2	2025-12-31	2026-01-02	shipped
356	45	2	2025-12-31	2026-01-02	shipped
357	71	3	2025-12-31	2026-01-02	shipped
358	80	3	2025-12-31	2026-01-02	shipped
359	74	3	2025-12-31	2026-01-02	shipped
360	13	3	2025-12-31	2026-01-02	shipped
361	68	1	2026-01-01	2026-01-03	shipped
362	49	1	2026-01-01	2026-01-03	shipped
363	45	1	2026-01-01	2026-01-03	shipped
364	75	1	2026-01-01	2026-01-03	shipped
365	46	2	2026-01-01	2026-01-03	shipped
366	39	2	2026-01-01	2026-01-03	shipped
367	50	2	2026-01-01	2026-01-03	partial
368	29	3	2026-01-01	2026-01-03	shipped
369	56	3	2026-01-01	2026-01-03	shipped
370	1	3	2026-01-01	2026-01-03	shipped
371	36	1	2026-01-02	2026-01-04	shipped
372	63	1	2026-01-02	2026-01-04	shipped
373	73	1	2026-01-02	2026-01-04	shipped
374	65	1	2026-01-02	2026-01-04	shipped
375	64	2	2026-01-02	2026-01-04	shipped
376	1	3	2026-01-02	2026-01-04	shipped
377	40	3	2026-01-02	2026-01-04	shipped
378	76	2	2026-01-04	2026-01-06	shipped
379	39	2	2026-01-04	2026-01-06	shipped
380	27	3	2026-01-04	2026-01-06	shipped
381	44	3	2026-01-04	2026-01-06	shipped
382	72	1	2026-01-05	2026-01-07	shipped
383	12	1	2026-01-05	2026-01-07	shipped
384	78	2	2026-01-05	2026-01-07	shipped
385	35	2	2026-01-05	2026-01-07	shipped
386	74	2	2026-01-05	2026-01-07	partial
387	32	3	2026-01-05	2026-01-07	shipped
388	58	2	2026-01-06	2026-01-08	shipped
389	44	2	2026-01-06	2026-01-08	shipped
390	47	2	2026-01-06	2026-01-08	shipped
391	15	2	2026-01-06	2026-01-08	shipped
392	68	3	2026-01-06	2026-01-08	shipped
393	32	1	2026-01-07	2026-01-09	shipped
394	45	1	2026-01-07	2026-01-09	shipped
395	66	2	2026-01-07	2026-01-09	shipped
396	68	2	2026-01-07	2026-01-09	shipped
397	28	3	2026-01-07	2026-01-09	shipped
398	63	3	2026-01-07	2026-01-09	shipped
399	52	1	2026-01-08	2026-01-10	shipped
400	27	1	2026-01-08	2026-01-10	shipped
401	54	1	2026-01-08	2026-01-10	partial
402	75	2	2026-01-08	2026-01-10	partial
403	56	2	2026-01-08	2026-01-10	partial
404	19	3	2026-01-08	2026-01-10	shipped
405	12	3	2026-01-08	2026-01-10	shipped
406	74	3	2026-01-08	2026-01-10	shipped
407	67	1	2026-01-09	2026-01-11	shipped
408	14	1	2026-01-09	2026-01-11	shipped
409	70	1	2026-01-09	2026-01-11	shipped
410	63	1	2026-01-09	2026-01-11	shipped
411	26	1	2026-01-09	2026-01-11	shipped
412	73	2	2026-01-09	2026-01-11	shipped
413	55	3	2026-01-09	2026-01-11	shipped
414	63	1	2026-01-10	2026-01-12	shipped
415	31	2	2026-01-10	2026-01-12	shipped
416	28	3	2026-01-10	2026-01-12	shipped
417	14	3	2026-01-10	2026-01-12	shipped
418	34	3	2026-01-10	2026-01-12	shipped
419	57	1	2026-01-11	2026-01-13	shipped
420	12	1	2026-01-11	2026-01-13	shipped
421	70	3	2026-01-11	2026-01-13	shipped
422	72	1	2026-01-12	2026-01-14	shipped
423	1	1	2026-01-12	2026-01-14	shipped
424	38	1	2026-01-12	2026-01-14	shipped
425	31	1	2026-01-12	2026-01-14	shipped
426	71	2	2026-01-12	2026-01-14	shipped
427	33	2	2026-01-12	2026-01-14	partial
428	78	2	2026-01-12	2026-01-14	shipped
429	61	2	2026-01-12	2026-01-14	partial
430	34	3	2026-01-12	2026-01-14	shipped
431	58	3	2026-01-12	2026-01-14	shipped
432	2	2	2026-01-13	2026-01-15	shipped
433	57	2	2026-01-13	2026-01-15	shipped
434	62	2	2026-01-13	2026-01-15	shipped
435	32	2	2026-01-13	2026-01-15	shipped
436	56	2	2026-01-13	2026-01-15	partial
437	61	2	2026-01-13	2026-01-15	shipped
438	74	2	2026-01-13	2026-01-15	shipped
439	5	3	2026-01-13	2026-01-15	shipped
440	40	3	2026-01-13	2026-01-15	shipped
441	22	1	2026-01-14	2026-01-16	shipped
442	11	1	2026-01-14	2026-01-16	shipped
443	57	2	2026-01-14	2026-01-16	shipped
444	44	3	2026-01-14	2026-01-16	shipped
445	3	1	2026-01-15	2026-01-17	shipped
446	16	2	2026-01-15	2026-01-17	shipped
447	76	2	2026-01-15	2026-01-17	shipped
448	70	2	2026-01-15	2026-01-17	shipped
449	72	3	2026-01-15	2026-01-17	shipped
450	62	3	2026-01-15	2026-01-17	shipped
451	71	1	2026-01-16	2026-01-18	shipped
452	46	2	2026-01-16	2026-01-18	shipped
453	31	3	2026-01-16	2026-01-18	shipped
454	71	3	2026-01-16	2026-01-18	shipped
455	25	3	2026-01-16	2026-01-18	shipped
456	40	3	2026-01-16	2026-01-18	shipped
457	26	2	2026-01-17	2026-01-19	shipped
458	40	2	2026-01-17	2026-01-19	shipped
459	31	1	2026-01-18	2026-01-20	partial
460	40	1	2026-01-18	2026-01-20	shipped
461	15	1	2026-01-19	2026-01-21	shipped
462	26	1	2026-01-19	2026-01-21	partial
463	10	1	2026-01-19	2026-01-21	shipped
464	30	1	2026-01-19	2026-01-21	shipped
465	58	1	2026-01-19	2026-01-21	partial
466	16	1	2026-01-19	2026-01-21	shipped
467	22	2	2026-01-19	2026-01-21	shipped
468	63	2	2026-01-19	2026-01-21	shipped
469	32	2	2026-01-19	2026-01-21	shipped
470	20	3	2026-01-19	2026-01-21	shipped
471	24	3	2026-01-19	2026-01-21	shipped
472	73	3	2026-01-19	2026-01-21	shipped
473	49	1	2026-01-20	2026-01-22	partial
474	26	1	2026-01-20	2026-01-22	shipped
475	50	1	2026-01-20	2026-01-22	shipped
476	21	1	2026-01-20	2026-01-22	partial
477	46	2	2026-01-20	2026-01-22	partial
478	1	2	2026-01-20	2026-01-22	shipped
479	26	2	2026-01-20	2026-01-22	partial
480	73	2	2026-01-20	2026-01-22	partial
481	65	3	2026-01-20	2026-01-22	partial
482	9	3	2026-01-20	2026-01-22	partial
483	35	3	2026-01-20	2026-01-22	shipped
484	22	3	2026-01-20	2026-01-22	partial
485	29	1	2026-01-21	2026-01-23	shipped
486	75	1	2026-01-21	2026-01-23	shipped
487	76	1	2026-01-21	2026-01-23	shipped
488	47	2	2026-01-21	2026-01-23	shipped
489	79	3	2026-01-21	2026-01-23	partial
490	12	3	2026-01-21	2026-01-23	shipped
491	40	3	2026-01-21	2026-01-23	shipped
492	20	3	2026-01-21	2026-01-23	shipped
493	66	1	2026-01-22	2026-01-24	shipped
494	50	1	2026-01-22	2026-01-24	shipped
495	63	1	2026-01-22	2026-01-24	shipped
496	31	2	2026-01-22	2026-01-24	partial
497	51	2	2026-01-22	2026-01-24	shipped
498	71	3	2026-01-22	2026-01-24	shipped
499	63	1	2026-01-23	2026-01-25	shipped
500	73	1	2026-01-23	2026-01-25	shipped
501	7	2	2026-01-23	2026-01-25	shipped
502	43	2	2026-01-23	2026-01-25	partial
503	46	3	2026-01-23	2026-01-25	shipped
504	75	1	2026-01-24	2026-01-26	shipped
505	26	3	2026-01-24	2026-01-26	shipped
506	10	1	2026-01-25	2026-01-27	shipped
507	76	2	2026-01-25	2026-01-27	shipped
508	59	2	2026-01-25	2026-01-27	shipped
509	10	2	2026-01-25	2026-01-27	shipped
510	54	3	2026-01-25	2026-01-27	shipped
511	70	1	2026-01-26	2026-01-28	shipped
512	53	1	2026-01-26	2026-01-28	shipped
513	58	1	2026-01-26	2026-01-28	partial
514	23	2	2026-01-26	2026-01-28	partial
515	63	2	2026-01-26	2026-01-28	shipped
516	77	2	2026-01-26	2026-01-28	shipped
517	15	2	2026-01-26	2026-01-28	shipped
518	38	3	2026-01-26	2026-01-28	partial
519	26	3	2026-01-26	2026-01-28	partial
520	18	3	2026-01-26	2026-01-28	shipped
521	9	3	2026-01-26	2026-01-28	shipped
522	4	3	2026-01-26	2026-01-28	shipped
523	38	1	2026-01-27	2026-01-29	shipped
524	40	1	2026-01-27	2026-01-29	shipped
525	38	1	2026-01-27	2026-01-29	shipped
526	22	2	2026-01-27	2026-01-29	shipped
527	77	2	2026-01-27	2026-01-29	partial
528	38	2	2026-01-27	2026-01-29	shipped
529	67	2	2026-01-27	2026-01-29	partial
530	72	3	2026-01-27	2026-01-29	partial
531	23	3	2026-01-27	2026-01-29	shipped
532	30	3	2026-01-27	2026-01-29	shipped
533	45	3	2026-01-27	2026-01-29	partial
534	26	3	2026-01-27	2026-01-29	shipped
535	52	1	2026-01-28	2026-01-30	shipped
536	31	1	2026-01-28	2026-01-30	shipped
537	27	2	2026-01-28	2026-01-30	shipped
538	5	3	2026-01-28	2026-01-30	shipped
539	8	1	2026-01-29	2026-01-31	shipped
540	5	1	2026-01-29	2026-01-31	shipped
541	38	3	2026-01-29	2026-01-31	shipped
542	8	2	2026-01-30	2026-02-01	shipped
543	20	2	2026-01-30	2026-02-01	shipped
544	17	2	2026-01-30	2026-02-01	shipped
545	10	2	2026-01-30	2026-02-01	shipped
546	24	2	2026-01-30	2026-02-01	shipped
547	28	3	2026-01-30	2026-02-01	partial
548	71	1	2026-01-31	2026-02-02	shipped
549	35	1	2026-01-31	2026-02-02	shipped
550	49	2	2026-02-01	2026-02-03	shipped
551	16	2	2026-02-01	2026-02-03	shipped
552	61	1	2026-02-02	2026-02-04	shipped
553	44	1	2026-02-02	2026-02-04	partial
554	36	1	2026-02-02	2026-02-04	shipped
555	21	1	2026-02-02	2026-02-04	shipped
556	26	2	2026-02-02	2026-02-04	shipped
557	26	3	2026-02-02	2026-02-04	shipped
558	51	3	2026-02-02	2026-02-04	shipped
559	55	3	2026-02-02	2026-02-04	shipped
560	59	3	2026-02-02	2026-02-04	shipped
561	60	3	2026-02-02	2026-02-04	partial
562	33	1	2026-02-03	2026-02-05	shipped
563	3	1	2026-02-03	2026-02-05	shipped
564	57	1	2026-02-03	2026-02-05	shipped
565	60	1	2026-02-03	2026-02-05	shipped
566	42	2	2026-02-03	2026-02-05	shipped
567	66	2	2026-02-03	2026-02-05	shipped
568	49	3	2026-02-03	2026-02-05	shipped
569	26	3	2026-02-03	2026-02-05	shipped
570	57	1	2026-02-04	2026-02-06	shipped
571	79	1	2026-02-04	2026-02-06	shipped
572	56	1	2026-02-04	2026-02-06	shipped
573	23	2	2026-02-04	2026-02-06	partial
574	13	3	2026-02-04	2026-02-06	shipped
575	67	3	2026-02-04	2026-02-06	shipped
576	53	3	2026-02-04	2026-02-06	shipped
577	51	1	2026-02-05	2026-02-07	shipped
578	73	1	2026-02-05	2026-02-07	shipped
579	35	1	2026-02-05	2026-02-07	shipped
580	79	2	2026-02-05	2026-02-07	shipped
581	61	2	2026-02-05	2026-02-07	shipped
582	72	3	2026-02-05	2026-02-07	shipped
583	8	1	2026-02-06	2026-02-08	shipped
584	2	1	2026-02-06	2026-02-08	partial
585	2	1	2026-02-06	2026-02-08	shipped
586	34	2	2026-02-06	2026-02-08	shipped
587	18	3	2026-02-06	2026-02-08	shipped
588	18	3	2026-02-06	2026-02-08	shipped
589	49	3	2026-02-06	2026-02-08	shipped
590	62	3	2026-02-06	2026-02-08	shipped
591	62	3	2026-02-06	2026-02-08	shipped
592	33	3	2026-02-06	2026-02-08	shipped
593	39	1	2026-02-07	2026-02-09	partial
594	36	3	2026-02-07	2026-02-09	shipped
595	12	3	2026-02-07	2026-02-09	shipped
596	54	2	2026-02-08	2026-02-10	shipped
597	39	2	2026-02-08	2026-02-10	shipped
598	66	2	2026-02-08	2026-02-10	shipped
599	62	3	2026-02-08	2026-02-10	shipped
600	11	3	2026-02-08	2026-02-10	shipped
601	12	3	2026-02-08	2026-02-10	shipped
602	19	1	2026-02-09	2026-02-11	shipped
603	79	1	2026-02-09	2026-02-11	shipped
604	39	2	2026-02-09	2026-02-11	shipped
605	19	2	2026-02-09	2026-02-11	shipped
606	34	2	2026-02-09	2026-02-11	shipped
607	42	2	2026-02-09	2026-02-11	shipped
608	29	2	2026-02-09	2026-02-11	shipped
609	2	3	2026-02-09	2026-02-11	partial
610	80	3	2026-02-09	2026-02-11	shipped
611	19	3	2026-02-09	2026-02-11	shipped
612	38	3	2026-02-09	2026-02-11	partial
613	71	3	2026-02-09	2026-02-11	shipped
614	8	1	2026-02-10	2026-02-12	shipped
615	30	1	2026-02-10	2026-02-12	shipped
616	56	3	2026-02-10	2026-02-12	shipped
617	9	1	2026-02-11	2026-02-13	shipped
618	71	1	2026-02-11	2026-02-13	shipped
619	32	1	2026-02-11	2026-02-13	shipped
620	12	1	2026-02-11	2026-02-13	shipped
621	62	2	2026-02-11	2026-02-13	shipped
622	60	2	2026-02-11	2026-02-13	shipped
623	72	2	2026-02-11	2026-02-13	shipped
624	37	2	2026-02-11	2026-02-13	partial
625	73	2	2026-02-11	2026-02-13	partial
626	9	3	2026-02-11	2026-02-13	shipped
627	54	1	2026-02-12	2026-02-14	shipped
628	50	1	2026-02-12	2026-02-14	shipped
629	3	1	2026-02-12	2026-02-14	partial
630	35	1	2026-02-12	2026-02-14	shipped
631	12	1	2026-02-12	2026-02-14	shipped
632	24	1	2026-02-12	2026-02-14	shipped
633	28	2	2026-02-12	2026-02-14	partial
634	55	2	2026-02-12	2026-02-14	partial
635	58	3	2026-02-12	2026-02-14	partial
636	36	3	2026-02-12	2026-02-14	partial
637	55	3	2026-02-12	2026-02-14	shipped
638	35	1	2026-02-13	2026-02-15	shipped
639	78	1	2026-02-13	2026-02-15	partial
640	52	2	2026-02-13	2026-02-15	shipped
641	36	2	2026-02-13	2026-02-15	shipped
642	30	2	2026-02-13	2026-02-15	shipped
643	47	2	2026-02-13	2026-02-15	shipped
644	14	3	2026-02-13	2026-02-15	shipped
645	57	3	2026-02-13	2026-02-15	shipped
646	32	1	2026-02-14	2026-02-16	partial
647	46	3	2026-02-14	2026-02-16	shipped
648	7	1	2026-02-15	2026-02-17	shipped
649	75	3	2026-02-15	2026-02-17	shipped
650	5	1	2026-02-16	2026-02-18	shipped
651	73	1	2026-02-16	2026-02-18	shipped
652	8	2	2026-02-16	2026-02-18	shipped
653	51	2	2026-02-16	2026-02-18	partial
654	39	2	2026-02-16	2026-02-18	shipped
655	60	2	2026-02-16	2026-02-18	shipped
656	21	3	2026-02-16	2026-02-18	partial
657	17	3	2026-02-16	2026-02-18	shipped
658	1	3	2026-02-16	2026-02-18	shipped
659	13	3	2026-02-16	2026-02-18	shipped
660	19	3	2026-02-16	2026-02-18	shipped
661	19	1	2026-02-17	2026-02-19	shipped
662	70	2	2026-02-17	2026-02-19	shipped
663	12	3	2026-02-17	2026-02-19	shipped
664	65	1	2026-02-18	2026-02-20	partial
665	61	1	2026-02-18	2026-02-20	shipped
666	27	2	2026-02-18	2026-02-20	shipped
667	16	2	2026-02-18	2026-02-20	shipped
668	37	2	2026-02-18	2026-02-20	shipped
669	19	2	2026-02-18	2026-02-20	shipped
670	29	3	2026-02-18	2026-02-20	shipped
671	3	3	2026-02-18	2026-02-20	shipped
672	71	3	2026-02-18	2026-02-20	shipped
673	58	3	2026-02-18	2026-02-20	partial
674	50	3	2026-02-18	2026-02-20	shipped
675	74	1	2026-02-19	2026-02-21	shipped
676	42	1	2026-02-19	2026-02-21	shipped
677	16	2	2026-02-19	2026-02-21	partial
678	73	2	2026-02-19	2026-02-21	shipped
679	24	2	2026-02-19	2026-02-21	shipped
680	58	2	2026-02-19	2026-02-21	partial
681	75	3	2026-02-19	2026-02-21	shipped
682	55	3	2026-02-19	2026-02-21	shipped
683	49	3	2026-02-19	2026-02-21	shipped
684	20	1	2026-02-20	2026-02-22	shipped
685	35	2	2026-02-20	2026-02-22	partial
686	62	2	2026-02-20	2026-02-22	shipped
687	44	3	2026-02-20	2026-02-22	shipped
688	4	2	2026-02-22	2026-02-24	shipped
689	38	1	2026-02-23	2026-02-25	shipped
690	56	1	2026-02-23	2026-02-25	shipped
691	26	2	2026-02-23	2026-02-25	shipped
692	65	2	2026-02-23	2026-02-25	shipped
693	4	3	2026-02-23	2026-02-25	partial
694	5	3	2026-02-23	2026-02-25	shipped
695	36	3	2026-02-23	2026-02-25	partial
696	45	1	2026-02-24	2026-02-26	shipped
697	52	1	2026-02-24	2026-02-26	shipped
698	26	1	2026-02-24	2026-02-26	shipped
699	17	1	2026-02-24	2026-02-26	partial
700	11	2	2026-02-24	2026-02-26	shipped
701	36	2	2026-02-24	2026-02-26	shipped
702	29	3	2026-02-24	2026-02-26	shipped
703	51	2	2026-02-25	2026-02-27	shipped
704	55	2	2026-02-25	2026-02-27	shipped
705	7	2	2026-02-25	2026-02-27	shipped
706	60	2	2026-02-25	2026-02-27	shipped
707	47	2	2026-02-25	2026-02-27	shipped
708	69	2	2026-02-25	2026-02-27	shipped
709	45	1	2026-02-26	2026-02-28	shipped
710	69	1	2026-02-26	2026-02-28	shipped
711	68	1	2026-02-26	2026-02-28	shipped
712	43	1	2026-02-26	2026-02-28	shipped
713	57	1	2026-02-26	2026-02-28	shipped
714	56	1	2026-02-26	2026-02-28	shipped
715	75	1	2026-02-26	2026-02-28	partial
716	40	2	2026-02-26	2026-02-28	shipped
717	74	2	2026-02-26	2026-02-28	shipped
718	77	1	2026-02-27	2026-03-01	shipped
719	54	1	2026-02-27	2026-03-01	shipped
720	43	1	2026-02-27	2026-03-01	shipped
721	22	1	2026-02-27	2026-03-01	shipped
722	49	3	2026-02-27	2026-03-01	shipped
723	7	3	2026-02-27	2026-03-01	partial
724	18	2	2026-02-28	2026-03-02	shipped
725	32	3	2026-02-28	2026-03-02	shipped
726	69	1	2026-03-02	2026-03-04	shipped
727	10	1	2026-03-02	2026-03-04	shipped
728	37	1	2026-03-02	2026-03-04	shipped
729	17	2	2026-03-02	2026-03-04	shipped
730	9	2	2026-03-02	2026-03-04	shipped
731	22	2	2026-03-02	2026-03-04	shipped
732	17	3	2026-03-02	2026-03-04	shipped
733	55	1	2026-03-03	2026-03-05	shipped
734	44	1	2026-03-03	2026-03-05	shipped
735	11	2	2026-03-03	2026-03-05	shipped
736	78	2	2026-03-03	2026-03-05	shipped
737	30	2	2026-03-03	2026-03-05	shipped
738	26	3	2026-03-03	2026-03-05	shipped
739	8	1	2026-03-04	2026-03-06	shipped
740	43	1	2026-03-04	2026-03-06	partial
741	29	1	2026-03-04	2026-03-06	partial
742	24	1	2026-03-04	2026-03-06	shipped
743	79	2	2026-03-04	2026-03-06	shipped
744	65	2	2026-03-04	2026-03-06	shipped
745	77	2	2026-03-04	2026-03-06	shipped
746	38	3	2026-03-04	2026-03-06	shipped
747	26	3	2026-03-04	2026-03-06	shipped
748	74	3	2026-03-04	2026-03-06	shipped
749	77	1	2026-03-05	2026-03-07	shipped
750	59	1	2026-03-05	2026-03-07	shipped
751	26	1	2026-03-05	2026-03-07	shipped
752	72	1	2026-03-05	2026-03-07	partial
753	54	2	2026-03-05	2026-03-07	shipped
754	3	3	2026-03-05	2026-03-07	shipped
755	12	3	2026-03-05	2026-03-07	shipped
756	4	3	2026-03-05	2026-03-07	shipped
757	57	1	2026-03-06	2026-03-08	shipped
758	39	1	2026-03-06	2026-03-08	partial
759	7	2	2026-03-06	2026-03-08	shipped
760	37	2	2026-03-06	2026-03-08	shipped
761	68	2	2026-03-06	2026-03-08	shipped
762	7	2	2026-03-06	2026-03-08	shipped
763	41	3	2026-03-06	2026-03-08	shipped
764	9	3	2026-03-06	2026-03-08	shipped
765	72	3	2026-03-06	2026-03-08	shipped
766	28	3	2026-03-06	2026-03-08	shipped
767	31	3	2026-03-06	2026-03-08	partial
768	8	1	2026-03-07	2026-03-09	shipped
769	24	2	2026-03-07	2026-03-09	shipped
770	48	2	2026-03-07	2026-03-09	shipped
771	5	2	2026-03-07	2026-03-09	shipped
772	59	3	2026-03-07	2026-03-09	shipped
773	21	1	2026-03-08	2026-03-10	shipped
774	53	1	2026-03-08	2026-03-10	shipped
775	38	3	2026-03-08	2026-03-10	shipped
776	62	3	2026-03-08	2026-03-10	partial
777	3	3	2026-03-08	2026-03-10	shipped
778	8	3	2026-03-08	2026-03-10	shipped
779	42	1	2026-03-09	2026-03-11	shipped
780	40	1	2026-03-09	2026-03-11	shipped
781	19	1	2026-03-09	2026-03-11	shipped
782	53	1	2026-03-09	2026-03-11	partial
783	29	2	2026-03-09	2026-03-11	shipped
784	74	3	2026-03-09	2026-03-11	shipped
785	70	3	2026-03-09	2026-03-11	partial
786	68	3	2026-03-09	2026-03-11	shipped
787	52	3	2026-03-09	2026-03-11	shipped
788	52	3	2026-03-09	2026-03-11	shipped
789	20	1	2026-03-10	2026-03-12	shipped
790	58	2	2026-03-10	2026-03-12	shipped
791	20	2	2026-03-10	2026-03-12	shipped
792	58	2	2026-03-10	2026-03-12	shipped
793	76	3	2026-03-10	2026-03-12	partial
794	1	3	2026-03-10	2026-03-12	partial
795	60	1	2026-03-11	2026-03-13	shipped
796	39	1	2026-03-11	2026-03-13	partial
797	4	1	2026-03-11	2026-03-13	shipped
798	18	1	2026-03-11	2026-03-13	shipped
799	62	1	2026-03-11	2026-03-13	partial
800	48	2	2026-03-11	2026-03-13	shipped
801	2	2	2026-03-11	2026-03-13	shipped
802	3	2	2026-03-11	2026-03-13	shipped
803	60	2	2026-03-11	2026-03-13	shipped
804	63	1	2026-03-12	2026-03-14	partial
805	58	1	2026-03-12	2026-03-14	partial
806	34	1	2026-03-12	2026-03-14	shipped
807	27	2	2026-03-12	2026-03-14	shipped
808	70	2	2026-03-12	2026-03-14	shipped
809	40	3	2026-03-12	2026-03-14	shipped
810	22	3	2026-03-12	2026-03-14	partial
811	48	3	2026-03-12	2026-03-14	shipped
812	46	1	2026-03-13	2026-03-15	shipped
813	29	1	2026-03-13	2026-03-15	partial
814	8	1	2026-03-13	2026-03-15	shipped
815	48	2	2026-03-13	2026-03-15	shipped
816	29	3	2026-03-13	2026-03-15	shipped
817	79	3	2026-03-13	2026-03-15	shipped
818	31	1	2026-03-14	2026-03-16	shipped
819	16	2	2026-03-14	2026-03-16	shipped
820	44	3	2026-03-14	2026-03-16	shipped
821	72	3	2026-03-14	2026-03-16	shipped
822	8	1	2026-03-15	2026-03-17	partial
823	71	1	2026-03-15	2026-03-17	partial
824	47	2	2026-03-15	2026-03-17	shipped
825	26	3	2026-03-15	2026-03-17	partial
826	75	3	2026-03-15	2026-03-17	shipped
827	4	3	2026-03-15	2026-03-17	shipped
828	15	1	2026-03-16	2026-03-18	shipped
829	45	2	2026-03-16	2026-03-18	shipped
830	42	2	2026-03-16	2026-03-18	shipped
831	33	2	2026-03-16	2026-03-18	shipped
832	63	2	2026-03-16	2026-03-18	shipped
833	32	2	2026-03-16	2026-03-18	shipped
834	77	2	2026-03-16	2026-03-18	shipped
835	15	2	2026-03-16	2026-03-18	shipped
836	29	2	2026-03-16	2026-03-18	shipped
837	80	3	2026-03-16	2026-03-18	shipped
838	37	3	2026-03-16	2026-03-18	shipped
839	46	1	2026-03-17	2026-03-19	partial
840	36	1	2026-03-17	2026-03-19	shipped
841	38	1	2026-03-17	2026-03-19	shipped
842	54	3	2026-03-17	2026-03-19	partial
843	68	3	2026-03-17	2026-03-19	shipped
844	67	3	2026-03-17	2026-03-19	shipped
845	67	3	2026-03-17	2026-03-19	shipped
846	30	1	2026-03-18	2026-03-20	partial
847	70	3	2026-03-18	2026-03-20	shipped
848	50	3	2026-03-18	2026-03-20	shipped
849	22	3	2026-03-18	2026-03-20	shipped
850	35	1	2026-03-19	2026-03-21	shipped
851	52	1	2026-03-19	2026-03-21	shipped
852	50	2	2026-03-19	2026-03-21	shipped
853	35	2	2026-03-19	2026-03-21	shipped
854	79	3	2026-03-19	2026-03-21	partial
855	28	3	2026-03-19	2026-03-21	partial
856	50	3	2026-03-19	2026-03-21	shipped
857	26	3	2026-03-19	2026-03-21	partial
858	73	3	2026-03-19	2026-03-21	shipped
859	6	3	2026-03-19	2026-03-21	partial
860	7	3	2026-03-19	2026-03-21	partial
861	77	1	2026-03-20	2026-03-22	shipped
862	74	1	2026-03-20	2026-03-22	partial
863	36	2	2026-03-20	2026-03-22	shipped
864	22	2	2026-03-20	2026-03-22	shipped
865	58	2	2026-03-20	2026-03-22	partial
866	69	2	2026-03-20	2026-03-22	shipped
867	3	3	2026-03-20	2026-03-22	partial
868	23	3	2026-03-20	2026-03-22	shipped
869	61	3	2026-03-20	2026-03-22	partial
870	23	2	2026-03-21	2026-03-23	shipped
871	17	2	2026-03-21	2026-03-23	shipped
872	26	3	2026-03-21	2026-03-23	shipped
873	76	1	2026-03-22	2026-03-24	partial
874	30	2	2026-03-22	2026-03-24	shipped
875	48	1	2026-03-23	2026-03-25	shipped
876	75	1	2026-03-23	2026-03-25	shipped
877	48	1	2026-03-23	2026-03-25	shipped
878	33	1	2026-03-23	2026-03-25	shipped
879	16	1	2026-03-23	2026-03-25	shipped
880	74	2	2026-03-23	2026-03-25	shipped
881	44	2	2026-03-23	2026-03-25	shipped
882	54	2	2026-03-23	2026-03-25	shipped
883	33	2	2026-03-23	2026-03-25	shipped
884	7	3	2026-03-23	2026-03-25	partial
885	48	3	2026-03-23	2026-03-25	partial
886	7	3	2026-03-23	2026-03-25	shipped
887	21	3	2026-03-23	2026-03-25	shipped
888	13	1	2026-03-24	2026-03-26	shipped
889	14	1	2026-03-24	2026-03-26	shipped
890	24	1	2026-03-24	2026-03-26	shipped
891	44	1	2026-03-24	2026-03-26	shipped
892	68	2	2026-03-24	2026-03-26	shipped
893	76	3	2026-03-24	2026-03-26	partial
894	4	3	2026-03-24	2026-03-26	shipped
895	34	1	2026-03-25	2026-03-27	shipped
896	76	2	2026-03-25	2026-03-27	shipped
897	72	3	2026-03-25	2026-03-27	shipped
898	46	3	2026-03-25	2026-03-27	shipped
899	56	3	2026-03-25	2026-03-27	partial
900	75	1	2026-03-26	2026-03-28	shipped
901	39	1	2026-03-26	2026-03-28	shipped
902	55	1	2026-03-26	2026-03-28	shipped
903	68	2	2026-03-26	2026-03-28	shipped
904	57	2	2026-03-26	2026-03-28	shipped
905	71	2	2026-03-26	2026-03-28	shipped
906	12	2	2026-03-26	2026-03-28	shipped
907	63	2	2026-03-26	2026-03-28	shipped
908	52	3	2026-03-26	2026-03-28	shipped
909	15	3	2026-03-26	2026-03-28	shipped
910	4	3	2026-03-26	2026-03-28	shipped
911	23	1	2026-03-27	2026-03-29	shipped
912	22	1	2026-03-27	2026-03-29	shipped
913	47	1	2026-03-27	2026-03-29	shipped
914	16	2	2026-03-27	2026-03-29	shipped
915	71	2	2026-03-27	2026-03-29	shipped
916	15	3	2026-03-27	2026-03-29	partial
917	17	3	2026-03-27	2026-03-29	shipped
918	64	3	2026-03-27	2026-03-29	shipped
919	65	3	2026-03-27	2026-03-29	shipped
920	2	1	2026-03-28	2026-03-30	shipped
921	20	1	2026-03-28	2026-03-30	shipped
922	37	3	2026-03-28	2026-03-30	shipped
923	64	1	2026-03-29	2026-03-31	shipped
924	34	1	2026-03-29	2026-03-31	shipped
925	80	2	2026-03-29	2026-03-31	shipped
926	29	3	2026-03-29	2026-03-31	partial
927	72	3	2026-03-29	2026-03-31	shipped
928	35	1	2026-03-30	2026-04-01	shipped
929	76	1	2026-03-30	2026-04-01	shipped
930	65	2	2026-03-30	2026-04-01	shipped
931	34	2	2026-03-30	2026-04-01	shipped
932	72	2	2026-03-30	2026-04-01	shipped
933	14	2	2026-03-30	2026-04-01	partial
934	78	3	2026-03-30	2026-04-01	partial
935	30	3	2026-03-30	2026-04-01	shipped
936	44	3	2026-03-30	2026-04-01	shipped
937	76	3	2026-03-30	2026-04-01	shipped
938	46	3	2026-03-30	2026-04-01	shipped
939	34	1	2026-03-31	2026-04-02	shipped
940	68	2	2026-03-31	2026-04-02	shipped
941	21	2	2026-03-31	2026-04-02	partial
942	56	2	2026-03-31	2026-04-02	shipped
943	67	3	2026-03-31	2026-04-02	shipped
944	23	3	2026-03-31	2026-04-02	shipped
945	65	3	2026-03-31	2026-04-02	shipped
946	54	3	2026-03-31	2026-04-02	shipped
947	26	1	2026-04-01	2026-04-03	shipped
948	44	1	2026-04-01	2026-04-03	shipped
949	16	2	2026-04-01	2026-04-03	shipped
950	68	3	2026-04-01	2026-04-03	partial
951	39	1	2026-04-02	2026-04-04	shipped
952	13	2	2026-04-02	2026-04-04	shipped
953	74	2	2026-04-02	2026-04-04	shipped
954	24	3	2026-04-02	2026-04-04	partial
955	78	3	2026-04-02	2026-04-04	shipped
956	54	3	2026-04-02	2026-04-04	shipped
957	17	1	2026-04-03	2026-04-05	partial
958	9	1	2026-04-03	2026-04-05	shipped
959	56	1	2026-04-03	2026-04-05	shipped
960	77	1	2026-04-03	2026-04-05	shipped
961	34	2	2026-04-03	2026-04-05	shipped
962	34	2	2026-04-03	2026-04-05	shipped
963	42	3	2026-04-03	2026-04-05	shipped
964	48	3	2026-04-03	2026-04-05	shipped
965	6	3	2026-04-03	2026-04-05	shipped
966	33	3	2026-04-03	2026-04-05	partial
967	55	3	2026-04-03	2026-04-05	partial
968	58	2	2026-04-04	2026-04-06	shipped
969	41	1	2026-04-05	2026-04-07	shipped
970	40	1	2026-04-06	2026-04-08	shipped
971	28	1	2026-04-06	2026-04-08	shipped
972	36	1	2026-04-06	2026-04-08	shipped
973	56	2	2026-04-06	2026-04-08	shipped
974	61	2	2026-04-06	2026-04-08	shipped
975	39	3	2026-04-06	2026-04-08	partial
976	4	1	2026-04-07	2026-04-09	shipped
977	24	2	2026-04-07	2026-04-09	shipped
978	13	2	2026-04-07	2026-04-09	shipped
979	15	2	2026-04-07	2026-04-09	shipped
980	25	2	2026-04-07	2026-04-09	shipped
981	72	2	2026-04-07	2026-04-09	shipped
982	33	2	2026-04-07	2026-04-09	shipped
983	4	2	2026-04-07	2026-04-09	shipped
984	78	3	2026-04-07	2026-04-09	shipped
985	25	3	2026-04-07	2026-04-09	shipped
986	33	3	2026-04-07	2026-04-09	shipped
987	30	3	2026-04-07	2026-04-09	partial
988	54	1	2026-04-08	2026-04-10	partial
989	69	1	2026-04-08	2026-04-10	shipped
990	47	1	2026-04-08	2026-04-10	partial
991	73	2	2026-04-08	2026-04-10	shipped
992	36	2	2026-04-08	2026-04-10	shipped
993	22	3	2026-04-08	2026-04-10	partial
994	35	3	2026-04-08	2026-04-10	partial
995	16	3	2026-04-08	2026-04-10	shipped
996	47	1	2026-04-09	2026-04-11	partial
997	31	1	2026-04-09	2026-04-11	partial
998	5	1	2026-04-09	2026-04-11	shipped
999	52	1	2026-04-09	2026-04-11	shipped
1000	52	2	2026-04-09	2026-04-11	shipped
1001	37	2	2026-04-09	2026-04-11	shipped
1002	80	1	2026-04-10	2026-04-12	partial
1003	47	1	2026-04-10	2026-04-12	shipped
1004	9	2	2026-04-10	2026-04-12	shipped
1005	27	2	2026-04-10	2026-04-12	shipped
1006	2	2	2026-04-10	2026-04-12	partial
1007	21	3	2026-04-10	2026-04-12	shipped
1008	23	3	2026-04-10	2026-04-12	shipped
1009	53	3	2026-04-10	2026-04-12	shipped
1010	68	3	2026-04-10	2026-04-12	shipped
1011	20	1	2026-04-11	2026-04-13	partial
1012	31	1	2026-04-11	2026-04-13	shipped
1013	74	1	2026-04-12	2026-04-14	shipped
1014	18	2	2026-04-12	2026-04-14	shipped
1015	61	3	2026-04-12	2026-04-14	shipped
1016	62	3	2026-04-12	2026-04-14	shipped
1017	43	1	2026-04-13	2026-04-15	shipped
1018	39	1	2026-04-13	2026-04-15	shipped
1019	5	2	2026-04-13	2026-04-15	shipped
1020	60	2	2026-04-13	2026-04-15	partial
1021	67	2	2026-04-13	2026-04-15	partial
1022	47	2	2026-04-13	2026-04-15	partial
1023	71	3	2026-04-13	2026-04-15	shipped
1024	76	1	2026-04-14	2026-04-16	shipped
1025	40	1	2026-04-14	2026-04-16	partial
1026	2	1	2026-04-14	2026-04-16	shipped
1027	76	1	2026-04-14	2026-04-16	shipped
1028	67	1	2026-04-14	2026-04-16	shipped
1029	62	1	2026-04-14	2026-04-16	shipped
1030	56	2	2026-04-14	2026-04-16	partial
1031	10	2	2026-04-14	2026-04-16	partial
1032	50	2	2026-04-14	2026-04-16	partial
1033	80	2	2026-04-14	2026-04-16	shipped
1034	80	2	2026-04-14	2026-04-16	partial
1035	1	3	2026-04-14	2026-04-16	partial
1036	4	3	2026-04-14	2026-04-16	shipped
1037	52	1	2026-04-15	2026-04-17	partial
1038	46	1	2026-04-15	2026-04-17	shipped
1039	73	1	2026-04-15	2026-04-17	shipped
1040	1	3	2026-04-15	2026-04-17	shipped
1041	25	3	2026-04-15	2026-04-17	shipped
1042	6	3	2026-04-15	2026-04-17	shipped
1043	30	1	2026-04-16	2026-04-18	partial
1044	68	1	2026-04-16	2026-04-18	shipped
1045	31	2	2026-04-16	2026-04-18	shipped
1046	72	2	2026-04-16	2026-04-18	partial
1047	23	2	2026-04-16	2026-04-18	partial
1048	30	3	2026-04-16	2026-04-18	partial
1049	52	3	2026-04-16	2026-04-18	shipped
1050	19	3	2026-04-16	2026-04-18	shipped
1051	80	1	2026-04-17	2026-04-19	shipped
1052	40	1	2026-04-17	2026-04-19	shipped
1053	74	2	2026-04-17	2026-04-19	shipped
1054	44	2	2026-04-17	2026-04-19	shipped
1055	72	3	2026-04-17	2026-04-19	partial
1056	38	3	2026-04-17	2026-04-19	shipped
1057	25	3	2026-04-17	2026-04-19	partial
1058	71	1	2026-04-18	2026-04-20	partial
1059	58	2	2026-04-18	2026-04-20	shipped
1060	21	1	2026-04-19	2026-04-21	shipped
1061	8	3	2026-04-19	2026-04-21	partial
1062	31	3	2026-04-19	2026-04-21	partial
1063	77	3	2026-04-19	2026-04-21	partial
1064	2	3	2026-04-19	2026-04-21	shipped
1065	76	1	2026-04-20	2026-04-22	partial
1066	52	1	2026-04-20	2026-04-22	shipped
1067	39	1	2026-04-20	2026-04-22	partial
1068	9	1	2026-04-20	2026-04-22	shipped
1069	34	1	2026-04-20	2026-04-22	partial
1070	17	2	2026-04-20	2026-04-22	shipped
1071	70	2	2026-04-20	2026-04-22	partial
1072	12	3	2026-04-20	2026-04-22	shipped
1073	50	3	2026-04-20	2026-04-22	partial
1074	65	3	2026-04-20	2026-04-22	shipped
1075	6	1	2026-04-21	2026-04-23	partial
1076	27	1	2026-04-21	2026-04-23	partial
1077	79	1	2026-04-21	2026-04-23	partial
1078	21	1	2026-04-21	2026-04-23	partial
1079	51	2	2026-04-21	2026-04-23	shipped
1080	3	2	2026-04-21	2026-04-23	shipped
1081	52	2	2026-04-21	2026-04-23	shipped
1082	62	3	2026-04-21	2026-04-23	shipped
1083	24	1	2026-04-22	2026-04-24	partial
1084	56	1	2026-04-23	2026-04-25	partial
1085	33	1	2026-04-23	2026-04-25	partial
1086	49	3	2026-04-23	2026-04-25	shipped
1087	29	3	2026-04-23	2026-04-25	shipped
1088	32	3	2026-04-23	2026-04-25	shipped
1089	18	3	2026-04-23	2026-04-25	shipped
1090	25	1	2026-04-24	2026-04-26	shipped
1091	20	1	2026-04-24	2026-04-26	partial
1092	76	1	2026-04-24	2026-04-26	partial
1093	26	2	2026-04-24	2026-04-26	shipped
1094	72	2	2026-04-24	2026-04-26	shipped
1095	76	3	2026-04-24	2026-04-26	shipped
1096	13	2	2026-04-25	2026-04-27	shipped
1097	76	3	2026-04-25	2026-04-27	shipped
1098	14	3	2026-04-25	2026-04-27	shipped
1099	64	3	2026-04-25	2026-04-27	partial
1100	12	1	2026-04-26	2026-04-28	partial
1101	43	1	2026-04-26	2026-04-28	shipped
1102	80	2	2026-04-26	2026-04-28	shipped
1103	70	1	2026-04-27	2026-04-29	shipped
1104	78	2	2026-04-27	2026-04-29	shipped
1105	6	2	2026-04-27	2026-04-29	shipped
1106	4	1	2026-04-28	2026-04-30	shipped
1107	73	1	2026-04-28	2026-04-30	shipped
1108	1	2	2026-04-28	2026-04-30	shipped
1109	1	3	2026-04-28	2026-04-30	partial
1110	20	3	2026-04-28	2026-04-30	partial
1111	61	1	2026-04-29	2026-05-01	shipped
1112	80	1	2026-04-29	2026-05-01	shipped
1113	68	2	2026-04-29	2026-05-01	shipped
1114	76	2	2026-04-29	2026-05-01	shipped
1115	12	3	2026-04-29	2026-05-01	shipped
1116	18	3	2026-04-29	2026-05-01	shipped
1117	33	3	2026-04-29	2026-05-01	partial
1118	7	3	2026-04-29	2026-05-01	shipped
1119	17	1	2026-04-30	2026-05-02	partial
1120	64	1	2026-04-30	2026-05-02	shipped
1121	38	1	2026-04-30	2026-05-02	shipped
1122	41	2	2026-04-30	2026-05-02	shipped
1123	23	3	2026-04-30	2026-05-02	shipped
1124	57	1	2026-05-01	2026-05-03	shipped
1125	34	2	2026-05-01	2026-05-03	shipped
1126	14	2	2026-05-01	2026-05-03	shipped
1127	67	2	2026-05-01	2026-05-03	shipped
1128	37	2	2026-05-01	2026-05-03	shipped
1129	69	3	2026-05-01	2026-05-03	shipped
1130	72	3	2026-05-01	2026-05-03	shipped
1131	39	3	2026-05-01	2026-05-03	shipped
1132	79	3	2026-05-02	2026-05-04	shipped
1133	40	3	2026-05-02	2026-05-04	shipped
1134	42	1	2026-05-03	2026-05-05	shipped
1135	23	1	2026-05-04	2026-05-06	shipped
1136	76	2	2026-05-04	2026-05-06	shipped
1137	23	2	2026-05-04	2026-05-06	shipped
1138	10	2	2026-05-04	2026-05-06	shipped
1139	76	3	2026-05-04	2026-05-06	shipped
1140	50	3	2026-05-04	2026-05-06	shipped
1141	53	1	2026-05-05	2026-05-07	shipped
1142	54	2	2026-05-05	2026-05-07	shipped
1143	27	2	2026-05-05	2026-05-07	shipped
1144	26	2	2026-05-05	2026-05-07	shipped
1145	16	3	2026-05-05	2026-05-07	shipped
1146	40	1	2026-05-06	2026-05-08	shipped
1147	28	2	2026-05-06	2026-05-08	shipped
1148	26	2	2026-05-06	2026-05-08	shipped
1149	33	3	2026-05-06	2026-05-08	shipped
1150	12	3	2026-05-06	2026-05-08	shipped
1151	9	1	2026-05-07	2026-05-09	shipped
1152	77	1	2026-05-07	2026-05-09	shipped
1153	50	1	2026-05-07	2026-05-09	shipped
1154	25	1	2026-05-07	2026-05-09	shipped
1155	37	3	2026-05-07	2026-05-09	shipped
1156	66	3	2026-05-07	2026-05-09	shipped
1157	42	3	2026-05-07	2026-05-09	shipped
1158	71	3	2026-05-07	2026-05-09	shipped
1159	49	3	2026-05-07	2026-05-09	shipped
1160	13	1	2026-05-08	2026-05-10	shipped
1161	33	1	2026-05-08	2026-05-10	partial
1162	46	1	2026-05-08	2026-05-10	shipped
1163	35	2	2026-05-08	2026-05-10	shipped
1164	5	2	2026-05-08	2026-05-10	shipped
1165	61	3	2026-05-08	2026-05-10	shipped
1166	3	3	2026-05-08	2026-05-10	shipped
1167	37	1	2026-05-09	2026-05-11	shipped
1168	8	1	2026-05-09	2026-05-11	shipped
1169	3	1	2026-05-09	2026-05-11	shipped
1170	42	1	2026-05-09	2026-05-11	shipped
1171	45	1	2026-05-09	2026-05-11	shipped
1172	69	3	2026-05-09	2026-05-11	shipped
1173	17	3	2026-05-09	2026-05-11	shipped
1174	39	2	2026-05-11	2026-05-13	partial
1175	52	2	2026-05-11	2026-05-13	partial
1176	58	3	2026-05-11	2026-05-13	shipped
1177	79	3	2026-05-11	2026-05-13	shipped
1178	60	3	2026-05-11	2026-05-13	partial
1179	52	3	2026-05-11	2026-05-13	shipped
1180	71	1	2026-05-12	2026-05-14	shipped
1181	4	1	2026-05-12	2026-05-14	shipped
1182	62	1	2026-05-12	2026-05-14	shipped
1183	29	1	2026-05-12	2026-05-14	shipped
1184	49	3	2026-05-12	2026-05-14	shipped
1185	44	1	2026-05-13	2026-05-15	shipped
1186	59	1	2026-05-13	2026-05-15	shipped
1187	34	1	2026-05-13	2026-05-15	shipped
1188	55	2	2026-05-13	2026-05-15	shipped
1189	47	2	2026-05-13	2026-05-15	shipped
1190	75	2	2026-05-13	2026-05-15	shipped
1191	41	2	2026-05-13	2026-05-15	partial
1192	73	3	2026-05-13	2026-05-15	partial
1193	69	1	2026-05-14	2026-05-16	shipped
1194	22	1	2026-05-14	2026-05-16	shipped
1195	58	2	2026-05-14	2026-05-16	partial
1196	21	2	2026-05-14	2026-05-16	shipped
1197	67	2	2026-05-14	2026-05-16	shipped
1198	52	3	2026-05-14	2026-05-16	partial
1199	58	1	2026-05-15	2026-05-17	shipped
1200	18	1	2026-05-15	2026-05-17	shipped
1201	75	1	2026-05-15	2026-05-17	shipped
1202	43	2	2026-05-15	2026-05-17	shipped
1203	9	2	2026-05-15	2026-05-17	shipped
1204	23	2	2026-05-15	2026-05-17	shipped
1205	54	3	2026-05-15	2026-05-17	partial
1206	14	3	2026-05-15	2026-05-17	shipped
1207	69	3	2026-05-15	2026-05-17	partial
1208	30	3	2026-05-15	2026-05-17	shipped
1209	24	3	2026-05-15	2026-05-17	shipped
1210	51	3	2026-05-15	2026-05-17	shipped
1211	10	1	2026-05-16	2026-05-18	shipped
1212	10	3	2026-05-16	2026-05-18	shipped
1213	12	2	2026-05-17	2026-05-19	partial
1214	44	1	2026-05-18	2026-05-20	shipped
1215	35	1	2026-05-18	2026-05-20	shipped
1216	18	1	2026-05-18	2026-05-20	shipped
1217	29	1	2026-05-18	2026-05-20	shipped
1218	74	2	2026-05-18	2026-05-20	partial
1219	16	2	2026-05-18	2026-05-20	partial
1220	76	2	2026-05-18	2026-05-20	shipped
1221	25	2	2026-05-18	2026-05-20	shipped
1222	65	3	2026-05-18	2026-05-20	shipped
1223	33	3	2026-05-18	2026-05-20	shipped
1224	40	3	2026-05-18	2026-05-20	partial
1225	5	3	2026-05-18	2026-05-20	shipped
1226	62	1	2026-05-19	2026-05-21	shipped
1227	16	1	2026-05-19	2026-05-21	shipped
1228	55	2	2026-05-19	2026-05-21	shipped
1229	37	2	2026-05-19	2026-05-21	shipped
1230	36	2	2026-05-19	2026-05-21	shipped
1231	37	3	2026-05-19	2026-05-21	partial
1232	13	3	2026-05-19	2026-05-21	shipped
1233	70	1	2026-05-20	2026-05-22	shipped
1234	34	1	2026-05-20	2026-05-22	shipped
1235	42	1	2026-05-20	2026-05-22	shipped
1236	57	1	2026-05-20	2026-05-22	shipped
1237	36	2	2026-05-20	2026-05-22	shipped
1238	4	3	2026-05-20	2026-05-22	shipped
1239	76	3	2026-05-20	2026-05-22	shipped
1240	60	3	2026-05-20	2026-05-22	shipped
1241	75	3	2026-05-20	2026-05-22	partial
1242	15	1	2026-05-21	2026-05-23	shipped
1243	12	1	2026-05-21	2026-05-23	shipped
1244	4	1	2026-05-21	2026-05-23	partial
1245	15	1	2026-05-21	2026-05-23	shipped
1246	70	2	2026-05-21	2026-05-23	shipped
1247	4	2	2026-05-21	2026-05-23	shipped
1248	26	2	2026-05-21	2026-05-23	shipped
1249	24	2	2026-05-21	2026-05-23	partial
1250	13	2	2026-05-21	2026-05-23	partial
1251	18	3	2026-05-21	2026-05-23	partial
1252	20	1	2026-05-22	2026-05-24	shipped
1253	10	1	2026-05-22	2026-05-24	partial
1254	37	2	2026-05-22	2026-05-24	shipped
1255	41	2	2026-05-22	2026-05-24	shipped
1256	57	2	2026-05-22	2026-05-24	partial
1257	31	3	2026-05-22	2026-05-24	partial
1258	24	1	2026-05-23	2026-05-25	shipped
1259	75	1	2026-05-23	2026-05-25	partial
1260	80	2	2026-05-23	2026-05-25	shipped
1261	77	2	2026-05-23	2026-05-25	shipped
1262	23	3	2026-05-23	2026-05-25	shipped
1263	40	1	2026-05-24	2026-05-26	shipped
1264	46	3	2026-05-24	2026-05-26	partial
1265	77	1	2026-05-25	2026-05-27	shipped
1266	30	1	2026-05-25	2026-05-27	partial
1267	70	1	2026-05-25	2026-05-27	shipped
1268	67	1	2026-05-25	2026-05-27	shipped
1269	45	2	2026-05-25	2026-05-27	shipped
1270	13	2	2026-05-25	2026-05-27	shipped
1271	80	2	2026-05-25	2026-05-27	partial
1272	69	3	2026-05-25	2026-05-27	shipped
1273	18	3	2026-05-25	2026-05-27	shipped
1274	23	3	2026-05-25	2026-05-27	shipped
1275	27	3	2026-05-25	2026-05-27	shipped
1276	46	1	2026-05-26	2026-05-28	partial
1277	17	1	2026-05-26	2026-05-28	partial
1278	38	2	2026-05-26	2026-05-28	shipped
1279	2	3	2026-05-26	2026-05-28	shipped
1280	61	3	2026-05-26	2026-05-28	shipped
1281	73	2	2026-05-27	2026-05-29	shipped
1282	45	3	2026-05-27	2026-05-29	shipped
1283	21	3	2026-05-27	2026-05-29	shipped
1284	77	3	2026-05-27	2026-05-29	shipped
1285	12	3	2026-05-27	2026-05-29	shipped
1286	15	1	2026-05-28	2026-05-30	shipped
1287	65	1	2026-05-28	2026-05-30	partial
1288	15	3	2026-05-28	2026-05-30	shipped
1289	12	1	2026-05-29	2026-05-31	shipped
1290	17	1	2026-05-29	2026-05-31	partial
1291	36	1	2026-05-29	2026-05-31	shipped
1292	43	2	2026-05-29	2026-05-31	partial
1293	31	2	2026-05-29	2026-05-31	shipped
1294	43	2	2026-05-29	2026-05-31	partial
1295	74	2	2026-05-29	2026-05-31	shipped
1296	8	3	2026-05-29	2026-05-31	shipped
1297	61	3	2026-05-29	2026-05-31	shipped
1298	40	1	2026-05-30	2026-06-01	shipped
1299	68	1	2026-05-30	2026-06-01	partial
1300	69	1	2026-05-31	2026-06-02	partial
1301	80	2	2026-05-31	2026-06-02	partial
1302	12	1	2026-06-01	2026-06-03	partial
1303	45	1	2026-06-01	2026-06-03	shipped
1304	62	1	2026-06-01	2026-06-03	partial
1305	10	2	2026-06-01	2026-06-03	shipped
1306	40	3	2026-06-01	2026-06-03	shipped
1307	72	3	2026-06-01	2026-06-03	shipped
1308	1	3	2026-06-01	2026-06-03	partial
1309	65	1	2026-06-02	2026-06-04	shipped
1310	71	2	2026-06-02	2026-06-04	shipped
1311	66	2	2026-06-02	2026-06-04	shipped
1312	13	3	2026-06-02	2026-06-04	shipped
1313	37	3	2026-06-02	2026-06-04	shipped
1314	48	3	2026-06-02	2026-06-04	shipped
1315	64	1	2026-06-03	2026-06-05	partial
1316	55	1	2026-06-03	2026-06-05	shipped
1317	47	1	2026-06-03	2026-06-05	shipped
1318	58	1	2026-06-03	2026-06-05	partial
1319	48	2	2026-06-03	2026-06-05	shipped
1320	32	2	2026-06-03	2026-06-05	shipped
1321	30	2	2026-06-03	2026-06-05	partial
1322	4	3	2026-06-03	2026-06-05	shipped
1323	24	3	2026-06-03	2026-06-05	shipped
1324	27	3	2026-06-03	2026-06-05	partial
1325	56	3	2026-06-03	2026-06-05	shipped
1326	61	1	2026-06-04	2026-06-06	shipped
1327	65	2	2026-06-04	2026-06-06	shipped
1328	29	2	2026-06-04	2026-06-06	shipped
1329	66	2	2026-06-04	2026-06-06	partial
1330	66	3	2026-06-04	2026-06-06	shipped
1331	30	1	2026-06-05	2026-06-07	shipped
1332	15	1	2026-06-05	2026-06-07	shipped
1333	68	1	2026-06-05	2026-06-07	shipped
1334	18	1	2026-06-05	2026-06-07	shipped
1335	47	2	2026-06-05	2026-06-07	partial
1336	13	3	2026-06-05	2026-06-07	shipped
1337	57	3	2026-06-05	2026-06-07	shipped
1338	63	3	2026-06-05	2026-06-07	shipped
1339	54	2	2026-06-06	2026-06-08	partial
1340	69	3	2026-06-06	2026-06-08	shipped
1341	11	3	2026-06-06	2026-06-08	partial
1342	41	1	2026-06-07	2026-06-09	shipped
1343	34	1	2026-06-07	2026-06-09	partial
1344	38	2	2026-06-07	2026-06-09	partial
1345	57	2	2026-06-07	2026-06-09	partial
1346	75	3	2026-06-07	2026-06-09	shipped
1347	21	3	2026-06-07	2026-06-09	shipped
1348	62	3	2026-06-07	2026-06-09	shipped
1349	42	1	2026-06-08	2026-06-10	shipped
1350	17	1	2026-06-08	2026-06-10	shipped
1351	70	1	2026-06-08	2026-06-10	shipped
1352	59	1	2026-06-08	2026-06-10	shipped
1353	65	2	2026-06-08	2026-06-10	shipped
1354	26	2	2026-06-08	2026-06-10	shipped
1355	34	2	2026-06-08	2026-06-10	partial
1356	42	2	2026-06-08	2026-06-10	shipped
1357	64	2	2026-06-08	2026-06-10	partial
1358	79	2	2026-06-08	2026-06-10	shipped
1359	21	3	2026-06-08	2026-06-10	shipped
1360	15	1	2026-06-09	2026-06-11	shipped
1361	20	2	2026-06-09	2026-06-11	partial
1362	7	2	2026-06-09	2026-06-11	partial
1363	74	2	2026-06-09	2026-06-11	shipped
1364	49	3	2026-06-09	2026-06-11	shipped
1365	61	3	2026-06-09	2026-06-11	shipped
1366	1	1	2026-06-10	2026-06-12	shipped
1367	37	1	2026-06-10	2026-06-12	partial
1368	16	2	2026-06-10	2026-06-12	shipped
1369	19	2	2026-06-10	2026-06-12	shipped
1370	4	2	2026-06-10	2026-06-12	shipped
1371	65	2	2026-06-10	2026-06-12	partial
1372	21	3	2026-06-10	2026-06-12	shipped
1373	45	3	2026-06-10	2026-06-12	shipped
1374	4	1	2026-06-11	2026-06-13	shipped
1375	63	1	2026-06-11	2026-06-13	shipped
1376	54	1	2026-06-11	2026-06-13	partial
1377	79	1	2026-06-11	2026-06-13	shipped
1378	68	2	2026-06-11	2026-06-13	partial
1379	13	2	2026-06-11	2026-06-13	shipped
1380	35	2	2026-06-11	2026-06-13	shipped
1381	18	2	2026-06-11	2026-06-13	shipped
1382	43	3	2026-06-11	2026-06-13	shipped
1383	34	3	2026-06-11	2026-06-13	shipped
1384	20	1	2026-06-12	2026-06-14	partial
1385	58	1	2026-06-12	2026-06-14	partial
1386	77	1	2026-06-12	2026-06-14	partial
1387	52	1	2026-06-12	2026-06-14	shipped
1388	45	1	2026-06-12	2026-06-14	partial
1389	43	1	2026-06-12	2026-06-14	shipped
1390	1	2	2026-06-12	2026-06-14	partial
1391	16	2	2026-06-12	2026-06-14	partial
1392	22	2	2026-06-12	2026-06-14	shipped
1393	68	3	2026-06-12	2026-06-14	shipped
1394	57	3	2026-06-12	2026-06-14	shipped
1395	31	3	2026-06-12	2026-06-14	shipped
1396	38	3	2026-06-12	2026-06-14	partial
1397	63	3	2026-06-12	2026-06-14	partial
1398	3	1	2026-06-13	2026-06-15	shipped
1399	1	3	2026-06-13	2026-06-15	shipped
1400	3	3	2026-06-13	2026-06-15	shipped
1401	6	1	2026-06-14	2026-06-16	shipped
1402	63	1	2026-06-14	2026-06-16	shipped
1403	65	2	2026-06-14	2026-06-16	partial
1404	36	2	2026-06-14	2026-06-16	partial
1405	32	2	2026-06-14	2026-06-16	shipped
1406	50	3	2026-06-14	2026-06-16	partial
1407	64	1	2026-06-15	2026-06-17	partial
1408	25	3	2026-06-15	2026-06-17	shipped
1409	61	3	2026-06-15	2026-06-17	partial
1410	3	1	2026-06-16	2026-06-18	shipped
1411	51	1	2026-06-16	2026-06-18	shipped
1412	28	2	2026-06-16	2026-06-18	shipped
1413	48	2	2026-06-16	2026-06-18	shipped
1414	17	2	2026-06-16	2026-06-18	shipped
1415	54	2	2026-06-16	2026-06-18	partial
1416	24	2	2026-06-16	2026-06-18	shipped
1417	11	2	2026-06-16	2026-06-18	partial
1418	71	3	2026-06-16	2026-06-18	partial
1419	25	3	2026-06-16	2026-06-18	partial
1420	75	3	2026-06-16	2026-06-18	partial
1421	69	1	2026-06-17	2026-06-19	partial
1422	48	1	2026-06-17	2026-06-19	partial
1423	40	2	2026-06-17	2026-06-19	partial
1424	57	2	2026-06-17	2026-06-19	partial
1425	15	3	2026-06-17	2026-06-19	partial
1426	14	3	2026-06-17	2026-06-19	shipped
1427	29	3	2026-06-17	2026-06-19	shipped
1428	21	3	2026-06-17	2026-06-19	shipped
1429	43	1	2026-06-18	2026-06-20	partial
1430	7	1	2026-06-18	2026-06-20	partial
1431	12	1	2026-06-18	2026-06-20	partial
1432	35	1	2026-06-18	2026-06-20	partial
1433	59	1	2026-06-18	2026-06-20	partial
1434	36	1	2026-06-18	2026-06-20	partial
1435	44	2	2026-06-18	2026-06-20	partial
1436	72	2	2026-06-18	2026-06-20	partial
1437	65	3	2026-06-18	2026-06-20	partial
1438	28	3	2026-06-18	2026-06-20	partial
1439	75	3	2026-06-18	2026-06-20	partial
1440	57	3	2026-06-18	2026-06-20	partial
1441	80	3	2026-06-18	2026-06-20	partial
1442	6	3	2026-06-18	2026-06-20	partial
1443	44	1	2026-06-19	2026-06-21	partial
1444	5	2	2026-06-19	2026-06-21	partial
1445	37	2	2026-06-19	2026-06-21	partial
1446	38	3	2026-06-19	2026-06-21	shipped
1447	43	1	2026-06-20	2026-06-22	shipped
1448	9	2	2026-06-20	2026-06-22	shipped
1449	50	3	2026-06-20	2026-06-22	shipped
1450	56	1	2026-06-22	2026-06-24	partial
1451	53	1	2026-06-22	2026-06-24	partial
1452	71	2	2026-06-22	2026-06-24	shipped
1453	16	2	2026-06-22	2026-06-24	shipped
1454	65	2	2026-06-22	2026-06-24	partial
1455	45	2	2026-06-22	2026-06-24	partial
1456	39	3	2026-06-22	2026-06-24	partial
1457	71	3	2026-06-22	2026-06-24	shipped
1458	64	3	2026-06-22	2026-06-24	shipped
1459	19	3	2026-06-22	2026-06-24	partial
1460	16	1	2026-06-23	2026-06-25	partial
1461	28	1	2026-06-23	2026-06-25	shipped
1462	26	2	2026-06-23	2026-06-25	partial
1463	19	2	2026-06-23	2026-06-25	partial
1464	30	1	2026-06-24	2026-06-26	partial
1465	26	2	2026-06-24	2026-06-26	partial
1466	66	2	2026-06-24	2026-06-26	partial
1467	61	3	2026-06-24	2026-06-26	partial
1468	70	3	2026-06-24	2026-06-26	partial
1469	80	3	2026-06-24	2026-06-26	partial
1470	34	3	2026-06-24	2026-06-26	partial
1471	65	3	2026-06-24	2026-06-26	partial
1472	79	3	2026-06-24	2026-06-26	partial
1473	46	1	2026-06-25	2026-06-27	shipped
1474	78	2	2026-06-25	2026-06-27	partial
1475	2	2	2026-06-25	2026-06-27	partial
1476	39	2	2026-06-25	2026-06-27	partial
1477	63	2	2026-06-25	2026-06-27	partial
1478	77	3	2026-06-25	2026-06-27	partial
1479	44	3	2026-06-25	2026-06-27	partial
1480	67	3	2026-06-25	2026-06-27	partial
1481	38	3	2026-06-25	2026-06-27	partial
1482	27	1	2026-06-26	2026-06-28	shipped
1483	39	1	2026-06-26	2026-06-28	shipped
1484	22	2	2026-06-26	2026-06-28	partial
1485	79	2	2026-06-26	2026-06-28	partial
1486	2	3	2026-06-26	2026-06-28	shipped
1487	31	1	2026-06-27	2026-06-29	shipped
1488	70	2	2026-06-27	2026-06-29	shipped
1489	28	2	2026-06-27	2026-06-29	shipped
1490	69	1	2026-06-28	2026-06-30	partial
1491	39	1	2026-06-28	2026-06-30	shipped
1492	18	3	2026-06-28	2026-06-30	partial
1493	73	1	2026-06-29	2026-07-01	shipped
1494	58	2	2026-06-29	2026-07-01	shipped
1495	46	2	2026-06-29	2026-07-01	partial
1496	26	2	2026-06-29	2026-07-01	partial
1497	72	2	2026-06-29	2026-07-01	shipped
1498	67	3	2026-06-29	2026-07-01	shipped
1499	2	3	2026-06-29	2026-07-01	shipped
1500	78	3	2026-06-29	2026-07-01	shipped
1501	41	3	2026-06-29	2026-07-01	partial
1502	25	3	2026-06-29	2026-07-01	partial
1503	33	3	2026-06-29	2026-07-01	shipped
1504	51	3	2026-06-29	2026-07-01	shipped
1505	20	3	2026-06-29	2026-07-01	shipped
1506	59	3	2026-06-29	2026-07-01	shipped
1507	5	3	2026-06-29	2026-07-01	shipped
1508	24	1	2026-06-30	2026-07-02	shipped
1509	39	1	2026-06-30	2026-07-02	shipped
1510	45	1	2026-06-30	2026-07-02	partial
1511	53	1	2026-06-30	2026-07-02	shipped
1512	8	1	2026-06-30	2026-07-02	shipped
1513	59	2	2026-06-30	2026-07-02	partial
1514	43	2	2026-06-30	2026-07-02	shipped
1515	34	2	2026-06-30	2026-07-02	shipped
1516	16	2	2026-06-30	2026-07-02	shipped
1517	22	2	2026-06-30	2026-07-02	shipped
1518	63	2	2026-06-30	2026-07-02	partial
1519	2	3	2026-06-30	2026-07-02	shipped
1520	27	3	2026-06-30	2026-07-02	partial
1521	43	3	2026-06-30	2026-07-02	shipped
1522	36	1	2026-07-01	2026-07-03	shipped
1523	31	1	2026-07-01	2026-07-03	shipped
1524	69	1	2026-07-01	2026-07-03	partial
1525	41	1	2026-07-01	2026-07-03	shipped
1526	51	2	2026-07-01	2026-07-03	shipped
1527	5	2	2026-07-01	2026-07-03	partial
1528	4	2	2026-07-01	2026-07-03	shipped
1529	66	2	2026-07-01	2026-07-03	shipped
1530	19	2	2026-07-01	2026-07-03	partial
1531	66	2	2026-07-01	2026-07-03	shipped
1532	35	2	2026-07-01	2026-07-03	shipped
1533	78	3	2026-07-01	2026-07-03	shipped
1534	1	1	2026-07-02	2026-07-04	partial
1535	28	2	2026-07-02	2026-07-04	shipped
1536	44	2	2026-07-02	2026-07-04	partial
1537	74	2	2026-07-02	2026-07-04	partial
1538	11	3	2026-07-02	2026-07-04	shipped
1539	19	3	2026-07-02	2026-07-04	shipped
1540	32	3	2026-07-02	2026-07-04	partial
1541	66	3	2026-07-02	2026-07-04	shipped
1542	39	1	2026-07-03	2026-07-05	shipped
1543	24	1	2026-07-03	2026-07-05	partial
1544	44	1	2026-07-03	2026-07-05	shipped
1545	72	1	2026-07-03	2026-07-05	shipped
1546	74	2	2026-07-03	2026-07-05	shipped
1547	80	2	2026-07-03	2026-07-05	shipped
1548	20	2	2026-07-03	2026-07-05	partial
1549	24	2	2026-07-03	2026-07-05	partial
1550	16	2	2026-07-03	2026-07-05	shipped
1551	17	3	2026-07-03	2026-07-05	shipped
1552	76	3	2026-07-03	2026-07-05	partial
1553	5	3	2026-07-03	2026-07-05	partial
1554	15	1	2026-07-04	2026-07-06	partial
1555	42	1	2026-07-04	2026-07-06	shipped
1556	40	1	2026-07-04	2026-07-06	partial
1557	59	3	2026-07-04	2026-07-06	shipped
1558	2	3	2026-07-04	2026-07-06	partial
1559	77	1	2026-07-05	2026-07-07	shipped
1560	14	1	2026-07-05	2026-07-07	partial
1561	55	2	2026-07-05	2026-07-07	partial
1562	63	2	2026-07-05	2026-07-07	partial
1563	5	3	2026-07-05	2026-07-07	shipped
1564	9	3	2026-07-05	2026-07-07	shipped
1565	24	3	2026-07-05	2026-07-07	shipped
1566	53	1	2026-07-06	2026-07-08	shipped
1567	68	1	2026-07-06	2026-07-08	partial
1568	52	3	2026-07-06	2026-07-08	partial
1569	44	3	2026-07-06	2026-07-08	partial
1570	59	1	2026-07-07	2026-07-09	shipped
1571	57	1	2026-07-07	2026-07-09	partial
1572	25	2	2026-07-07	2026-07-09	partial
1573	45	2	2026-07-07	2026-07-09	shipped
1574	59	2	2026-07-07	2026-07-09	shipped
1575	23	2	2026-07-07	2026-07-09	shipped
1576	12	2	2026-07-07	2026-07-09	partial
1577	62	3	2026-07-07	2026-07-09	shipped
1578	33	3	2026-07-07	2026-07-09	shipped
1579	60	1	2026-07-08	2026-07-10	shipped
1580	18	1	2026-07-08	2026-07-10	shipped
1581	73	1	2026-07-08	2026-07-10	shipped
1582	4	1	2026-07-08	2026-07-10	shipped
1583	29	1	2026-07-08	2026-07-10	shipped
1584	34	2	2026-07-08	2026-07-10	partial
1585	9	2	2026-07-08	2026-07-10	shipped
1586	56	2	2026-07-08	2026-07-10	partial
1587	53	2	2026-07-08	2026-07-10	shipped
1588	13	3	2026-07-08	2026-07-10	partial
1589	32	3	2026-07-08	2026-07-10	partial
1590	57	3	2026-07-08	2026-07-10	partial
1591	78	3	2026-07-08	2026-07-10	cut
1592	66	3	2026-07-08	2026-07-10	partial
1593	58	1	2026-07-09	2026-07-11	partial
1594	52	1	2026-07-09	2026-07-11	shipped
1595	33	2	2026-07-09	2026-07-11	partial
1596	17	2	2026-07-09	2026-07-11	partial
1597	79	2	2026-07-09	2026-07-11	partial
1598	35	3	2026-07-09	2026-07-11	shipped
1599	78	3	2026-07-09	2026-07-11	partial
1600	10	3	2026-07-09	2026-07-11	partial
1601	7	3	2026-07-09	2026-07-11	partial
1602	46	3	2026-07-09	2026-07-11	partial
1603	29	3	2026-07-09	2026-07-11	partial
1604	67	1	2026-07-10	2026-07-12	shipped
1605	37	1	2026-07-10	2026-07-12	partial
1606	59	2	2026-07-10	2026-07-12	shipped
1607	72	3	2026-07-10	2026-07-12	partial
1608	75	3	2026-07-10	2026-07-12	partial
1609	23	3	2026-07-10	2026-07-12	shipped
1610	78	3	2026-07-10	2026-07-12	shipped
1611	43	3	2026-07-10	2026-07-12	partial
1612	69	3	2026-07-10	2026-07-12	partial
1613	15	1	2026-07-11	2026-07-13	partial
1614	9	2	2026-07-11	2026-07-13	shipped
1615	53	3	2026-07-11	2026-07-13	partial
1616	1	1	2026-07-13	2026-07-15	shipped
1617	79	1	2026-07-13	2026-07-15	shipped
1618	50	1	2026-07-13	2026-07-15	partial
1619	23	2	2026-07-13	2026-07-15	partial
1620	35	2	2026-07-13	2026-07-15	shipped
1621	64	2	2026-07-13	2026-07-15	shipped
1622	5	2	2026-07-13	2026-07-15	partial
1623	57	3	2026-07-13	2026-07-15	shipped
1624	30	3	2026-07-13	2026-07-15	partial
1625	74	3	2026-07-13	2026-07-15	partial
1626	57	1	2026-07-14	2026-07-16	shipped
1627	52	1	2026-07-14	2026-07-16	shipped
1628	45	2	2026-07-14	2026-07-16	shipped
1629	8	2	2026-07-14	2026-07-16	shipped
1630	80	3	2026-07-14	2026-07-16	partial
1631	35	3	2026-07-14	2026-07-16	partial
1632	60	3	2026-07-14	2026-07-16	partial
1633	52	1	2026-07-15	2026-07-17	shipped
1634	8	1	2026-07-15	2026-07-17	partial
1635	60	2	2026-07-15	2026-07-17	shipped
1636	43	3	2026-07-15	2026-07-17	shipped
1637	58	3	2026-07-15	2026-07-17	partial
1638	12	3	2026-07-15	2026-07-17	partial
1639	51	1	2026-07-16	2026-07-18	partial
1640	76	1	2026-07-16	2026-07-18	partial
1641	74	2	2026-07-16	2026-07-18	partial
1642	24	2	2026-07-16	2026-07-18	shipped
1643	74	3	2026-07-16	2026-07-18	shipped
1644	50	3	2026-07-16	2026-07-18	shipped
1645	65	3	2026-07-16	2026-07-18	shipped
1646	5	1	2026-07-17	2026-07-19	shipped
1647	77	1	2026-07-17	2026-07-19	partial
1648	21	2	2026-07-17	2026-07-19	shipped
1649	12	2	2026-07-17	2026-07-19	shipped
1650	49	2	2026-07-17	2026-07-19	shipped
1651	46	2	2026-07-17	2026-07-19	partial
1652	47	2	2026-07-18	2026-07-20	shipped
1653	14	2	2026-07-18	2026-07-20	shipped
1654	11	1	2026-07-19	2026-07-21	shipped
1655	17	1	2026-07-20	2026-07-22	shipped
1656	33	1	2026-07-20	2026-07-22	shipped
1657	45	1	2026-07-20	2026-07-22	shipped
1658	21	1	2026-07-20	2026-07-22	shipped
1659	14	1	2026-07-20	2026-07-22	partial
1660	78	2	2026-07-20	2026-07-22	partial
1661	21	3	2026-07-20	2026-07-22	shipped
1662	10	3	2026-07-20	2026-07-22	partial
1663	18	1	2026-07-21	2026-07-23	shipped
1664	24	1	2026-07-21	2026-07-23	shipped
1665	70	1	2026-07-21	2026-07-23	shipped
1666	41	1	2026-07-21	2026-07-23	shipped
1667	63	1	2026-07-21	2026-07-23	shipped
1668	65	1	2026-07-21	2026-07-23	shipped
1669	55	2	2026-07-21	2026-07-23	partial
1670	64	2	2026-07-21	2026-07-23	shipped
1671	61	2	2026-07-21	2026-07-23	shipped
1672	26	2	2026-07-21	2026-07-23	partial
1673	3	2	2026-07-21	2026-07-23	partial
1674	5	2	2026-07-21	2026-07-23	partial
1675	14	2	2026-07-21	2026-07-23	shipped
1676	1	3	2026-07-21	2026-07-23	shipped
1677	59	3	2026-07-21	2026-07-23	partial
1678	79	3	2026-07-21	2026-07-23	shipped
1679	15	1	2026-07-22	2026-07-24	shipped
1680	58	1	2026-07-22	2026-07-24	partial
1681	75	1	2026-07-22	2026-07-24	shipped
1682	25	1	2026-07-22	2026-07-24	shipped
1683	43	1	2026-07-22	2026-07-24	partial
1684	34	1	2026-07-22	2026-07-24	shipped
1685	33	2	2026-07-22	2026-07-24	partial
1686	79	2	2026-07-22	2026-07-24	shipped
1687	79	2	2026-07-22	2026-07-24	shipped
1688	34	2	2026-07-22	2026-07-24	partial
1689	3	1	2026-07-23	2026-07-25	shipped
1690	62	2	2026-07-23	2026-07-25	shipped
1691	80	2	2026-07-23	2026-07-25	shipped
1692	47	2	2026-07-23	2026-07-25	partial
1693	38	3	2026-07-23	2026-07-25	shipped
1694	32	3	2026-07-23	2026-07-25	shipped
1695	77	3	2026-07-23	2026-07-25	shipped
1696	25	3	2026-07-23	2026-07-25	partial
1697	75	3	2026-07-23	2026-07-25	partial
1698	34	1	2026-07-24	2026-07-26	partial
1699	62	2	2026-07-24	2026-07-26	shipped
1700	63	2	2026-07-24	2026-07-26	partial
1701	27	2	2026-07-24	2026-07-26	shipped
1702	36	2	2026-07-24	2026-07-26	partial
1703	56	3	2026-07-24	2026-07-26	shipped
1704	22	3	2026-07-24	2026-07-26	shipped
1705	70	1	2026-07-25	2026-07-27	partial
1706	62	2	2026-07-25	2026-07-27	partial
1707	31	3	2026-07-25	2026-07-27	shipped
1708	20	3	2026-07-25	2026-07-27	shipped
1709	39	2	2026-07-26	2026-07-28	partial
1710	28	1	2026-07-27	2026-07-29	shipped
1711	65	1	2026-07-27	2026-07-29	shipped
1712	70	1	2026-07-27	2026-07-29	shipped
1713	13	2	2026-07-27	2026-07-29	shipped
1714	2	2	2026-07-27	2026-07-29	partial
1715	8	2	2026-07-27	2026-07-29	shipped
1716	59	2	2026-07-27	2026-07-29	partial
1717	42	3	2026-07-27	2026-07-29	shipped
1718	39	3	2026-07-27	2026-07-29	partial
1719	5	3	2026-07-27	2026-07-29	shipped
1720	70	1	2026-07-28	2026-07-30	shipped
1721	38	1	2026-07-28	2026-07-30	shipped
1722	6	2	2026-07-28	2026-07-30	partial
1723	21	3	2026-07-28	2026-07-30	partial
1724	2	3	2026-07-28	2026-07-30	shipped
1725	33	3	2026-07-28	2026-07-30	shipped
1726	55	1	2026-07-29	2026-07-31	partial
1727	6	1	2026-07-29	2026-07-31	shipped
1728	48	1	2026-07-29	2026-07-31	shipped
1729	80	3	2026-07-29	2026-07-31	shipped
1730	64	3	2026-07-29	2026-07-31	shipped
1731	26	1	2026-07-30	2026-08-01	partial
1732	56	1	2026-07-30	2026-08-01	partial
1733	40	1	2026-07-30	2026-08-01	shipped
1734	17	2	2026-07-30	2026-08-01	partial
1735	28	2	2026-07-30	2026-08-01	partial
1736	68	2	2026-07-30	2026-08-01	partial
1737	58	3	2026-07-30	2026-08-01	partial
1738	41	1	2026-07-31	2026-08-02	shipped
1739	25	1	2026-07-31	2026-08-02	shipped
1740	32	1	2026-07-31	2026-08-02	partial
1741	60	2	2026-07-31	2026-08-02	shipped
1742	61	2	2026-07-31	2026-08-02	shipped
1743	41	2	2026-07-31	2026-08-02	shipped
1744	36	2	2026-07-31	2026-08-02	shipped
1745	52	3	2026-07-31	2026-08-02	shipped
1746	51	3	2026-07-31	2026-08-02	shipped
1747	33	3	2026-07-31	2026-08-02	shipped
1748	52	3	2026-07-31	2026-08-02	shipped
1749	49	3	2026-07-31	2026-08-02	shipped
\.
COPY sales_order_lines (order_line_id, order_id, product_id, qty_ordered, qty_shipped, unit_price, ship_date) FROM stdin;
1	1	9	24	24	129.89	2025-11-04
2	1	10	48	48	74.91	2025-11-04
3	1	18	72	72	82.83	2025-11-04
4	1	16	24	24	161.56	2025-11-04
5	1	39	12	12	32.52	2025-11-04
6	2	34	24	24	132.21	2025-11-04
7	2	22	6	6	162.12	2025-11-04
8	2	8	18	18	48.81	2025-11-04
9	2	37	72	72	126.98	2025-11-04
10	2	38	36	36	152.33	2025-11-04
11	3	16	24	24	158.33	2025-11-03
12	3	37	24	24	126.98	2025-11-03
13	3	32	6	6	121.7	2025-11-03
14	4	3	24	24	25.4	2025-11-03
15	4	37	48	48	123.09	2025-11-03
16	5	4	24	24	37.77	2025-11-03
17	5	16	12	12	161.56	2025-11-03
18	6	3	12	12	25.4	2025-11-03
19	6	16	24	24	153.48	2025-11-03
20	6	23	12	12	44.56	2025-11-03
21	6	2	12	12	99.11	2025-11-03
22	6	15	24	24	161.7	2025-11-03
23	7	24	24	24	36.72	2025-11-03
24	7	1	18	18	12.49	2025-11-03
25	7	16	24	24	161.56	2025-11-03
26	7	31	48	48	150.44	2025-11-03
27	8	14	24	24	116.19	2025-11-04
28	8	21	72	72	59.84	2025-11-04
29	8	35	12	12	125.1	2025-11-04
30	8	23	36	36	46.91	2025-11-04
31	9	24	72	72	36.72	2025-11-03
32	9	18	24	24	82.83	2025-11-03
33	9	23	36	36	46.91	2025-11-03
34	9	16	12	12	161.56	2025-11-03
35	9	27	36	36	17.24	2025-11-03
36	10	6	48	48	154.57	2025-11-03
37	10	30	72	72	184.29	2025-11-03
38	10	27	24	24	17.24	2025-11-03
39	10	4	24	24	37.77	2025-11-03
40	11	38	12	12	152.33	2025-11-04
41	11	23	24	24	45.97	2025-11-04
42	12	9	72	72	123.4	2025-11-04
43	12	16	12	12	153.48	2025-11-04
44	12	31	48	48	142.92	2025-11-04
45	12	30	72	72	175.08	2025-11-04
46	13	31	72	72	142.92	2025-11-05
47	13	29	18	18	44.96	2025-11-05
48	14	16	24	24	161.56	2025-11-05
49	14	39	6	6	32.52	2025-11-05
50	14	4	24	24	37.77	2025-11-05
51	14	3	12	12	26.74	2025-11-05
52	15	16	12	12	161.56	2025-11-04
53	15	38	24	24	155.44	2025-11-04
54	15	1	18	18	12.49	2025-11-04
55	16	37	72	72	126.98	2025-11-05
56	16	25	6	6	167.68	2025-11-05
57	16	11	12	12	191.14	2025-11-05
58	16	20	18	18	67.24	2025-11-05
59	16	15	36	36	166.81	2025-11-05
60	17	27	36	36	16.38	2025-11-06
61	17	15	36	36	161.7	2025-11-06
62	17	17	18	18	50.36	2025-11-06
63	17	24	48	48	34.88	2025-11-06
64	17	22	18	18	157.16	2025-11-06
65	18	15	36	36	161.7	2025-11-05
66	18	31	72	72	142.92	2025-11-05
67	19	37	48	48	129.57	2025-11-05
68	19	5	72	72	111.03	2025-11-05
69	19	32	6	6	124.18	2025-11-05
70	19	27	36	36	17.24	2025-11-05
71	19	31	48	48	150.44	2025-11-05
72	20	18	72	72	82.83	2025-11-05
73	20	22	12	12	165.43	2025-11-05
74	21	29	18	18	47.33	2025-11-06
75	21	22	12	12	165.43	2025-11-06
76	22	37	72	72	123.09	2025-11-05
77	22	7	18	18	151.96	2025-11-05
78	22	13	24	24	92.66	2025-11-05
79	22	5	24	24	105.48	2025-11-05
80	23	5	24	24	108.81	2025-11-05
81	23	23	24	24	45.97	2025-11-05
82	23	2	18	18	102.24	2025-11-05
83	23	15	12	12	166.81	2025-11-05
84	24	5	24	24	111.03	2025-11-05
85	24	37	48	48	129.57	2025-11-05
86	24	25	12	12	171.1	2025-11-05
87	24	23	36	36	46.91	2025-11-05
88	24	26	6	6	55.53	2025-11-05
89	25	11	6	6	185.29	2025-11-06
90	25	2	6	6	99.11	2025-11-06
91	25	24	72	72	34.88	2025-11-06
92	26	31	24	24	150.44	2025-11-05
93	26	26	18	18	55.53	2025-11-05
94	26	9	72	72	129.89	2025-11-05
95	27	12	48	48	142.67	2025-11-06
96	27	13	24	24	95.59	2025-11-06
97	27	37	72	72	126.98	2025-11-06
98	27	30	72	72	180.6	2025-11-06
99	27	29	18	18	46.38	2025-11-06
100	28	39	18	18	32.52	2025-11-07
101	28	9	48	48	129.89	2025-11-07
102	28	29	18	18	47.33	2025-11-07
103	29	1	18	18	12.49	2025-11-07
104	29	38	36	36	155.44	2025-11-07
105	29	29	6	6	47.33	2025-11-07
106	30	37	48	48	129.57	2025-11-06
107	30	25	6	6	171.1	2025-11-06
108	31	6	24	24	146.84	2025-11-07
109	31	16	12	12	153.48	2025-11-07
110	31	18	24	24	78.69	2025-11-07
111	32	31	72	72	142.92	2025-11-07
112	32	39	12	12	30.89	2025-11-07
113	33	27	12	12	17.24	2025-11-07
114	33	12	48	48	145.58	2025-11-07
115	33	4	36	36	37.77	2025-11-07
116	33	5	48	48	111.03	2025-11-07
117	33	38	12	12	155.44	2025-11-07
118	34	17	12	12	50.36	2025-11-07
119	34	31	24	24	142.92	2025-11-07
120	34	26	12	12	52.75	2025-11-07
121	35	25	12	12	171.1	2025-11-07
122	35	2	18	18	104.33	2025-11-07
123	36	4	12	12	37.77	2025-11-07
124	36	35	36	36	125.1	2025-11-07
125	36	24	48	48	36.72	2025-11-07
126	37	16	24	24	161.56	2025-11-07
127	37	5	48	48	111.03	2025-11-07
128	37	4	36	36	37.77	2025-11-07
129	38	24	72	72	34.88	2025-11-07
130	38	38	12	12	147.67	2025-11-07
131	38	20	18	18	65.18	2025-11-07
132	38	16	36	36	153.48	2025-11-07
133	39	13	36	36	97.54	2025-11-10
134	39	15	36	36	170.21	2025-11-10
135	39	26	6	6	55.53	2025-11-10
136	39	31	48	48	150.44	2025-11-10
137	40	27	24	24	17.24	2025-11-09
138	40	19	48	48	153.58	2025-11-09
139	40	9	48	48	129.89	2025-11-09
140	40	23	12	12	46.91	2025-11-09
141	41	24	24	24	36.72	2025-11-10
142	41	33	6	6	117.28	2025-11-10
143	42	14	36	36	110.38	2025-11-10
144	42	25	6	6	162.54	2025-11-10
145	43	37	72	72	123.09	2025-11-10
146	43	6	24	24	146.84	2025-11-10
147	43	29	18	18	44.96	2025-11-10
148	44	26	6	6	55.53	2025-11-10
149	44	30	48	48	184.29	2025-11-10
150	44	6	24	24	154.57	2025-11-10
151	44	31	72	72	150.44	2025-11-10
152	45	22	12	12	162.12	2025-11-11
153	45	37	72	72	126.98	2025-11-11
154	45	6	24	24	151.48	2025-11-11
155	45	38	12	12	152.33	2025-11-11
156	46	33	18	18	114.93	2025-11-10
157	46	30	72	72	180.6	2025-11-10
158	46	39	18	18	31.87	2025-11-10
159	47	31	48	48	142.92	2025-11-10
160	47	6	24	24	146.84	2025-11-10
161	47	17	6	6	50.36	2025-11-10
162	48	5	72	72	108.81	2025-11-10
163	48	12	24	24	142.67	2025-11-10
164	48	6	72	72	151.48	2025-11-10
165	49	7	18	18	159.96	2025-11-10
166	49	3	12	12	26.74	2025-11-10
167	49	40	18	18	38.67	2025-11-10
168	50	32	12	12	117.97	2025-11-10
169	50	14	24	24	110.38	2025-11-10
170	51	38	24	24	147.67	2025-11-10
171	51	6	72	72	146.84	2025-11-10
172	51	22	6	6	157.16	2025-11-10
173	51	33	18	18	111.42	2025-11-10
174	52	23	12	12	45.97	2025-11-12
175	52	11	12	12	191.14	2025-11-12
176	52	14	36	36	113.87	2025-11-12
177	52	34	12	12	132.21	2025-11-12
178	52	19	48	48	150.51	2025-11-12
179	53	37	48	48	129.57	2025-11-11
180	53	23	24	24	46.91	2025-11-11
181	53	27	12	12	17.24	2025-11-11
182	53	38	24	24	155.44	2025-11-11
183	54	22	18	18	165.43	2025-11-13
184	54	38	24	24	155.44	2025-11-13
185	54	25	18	18	171.1	2025-11-13
186	54	1	12	12	12.49	2025-11-13
187	55	12	48	48	145.58	2025-11-12
188	55	31	72	72	150.44	2025-11-12
189	55	37	72	72	129.57	2025-11-12
190	55	11	6	6	195.04	2025-11-12
191	56	27	36	36	16.9	2025-11-13
192	56	13	36	36	95.59	2025-11-13
193	57	22	6	6	162.12	2025-11-13
194	57	5	24	24	108.81	2025-11-13
195	57	30	48	48	180.6	2025-11-13
196	57	20	18	18	67.24	2025-11-13
197	57	28	24	24	172.72	2025-11-13
198	58	17	12	12	51.95	2025-11-13
199	58	20	18	18	67.24	2025-11-13
200	58	22	6	6	162.12	2025-11-13
201	59	29	18	18	47.33	2025-11-14
202	59	5	72	72	111.03	2025-11-14
203	59	34	24	24	134.91	2025-11-14
204	60	38	36	36	152.33	2025-11-14
205	60	25	18	18	167.68	2025-11-14
206	60	10	48	48	73.41	2025-11-14
207	60	39	18	18	31.87	2025-11-14
208	60	9	72	72	127.29	2025-11-14
209	61	8	18	18	49.81	2025-11-14
210	61	38	36	36	155.44	2025-11-14
211	61	3	24	24	26.74	2025-11-14
212	61	21	48	48	59.84	2025-11-14
213	61	33	6	6	117.28	2025-11-14
214	62	22	6	6	162.12	2025-11-15
215	62	40	12	12	37.9	2025-11-15
216	62	29	6	6	46.38	2025-11-15
217	63	24	24	24	36.72	2025-11-15
218	63	6	72	72	154.57	2025-11-15
219	63	4	12	12	37.77	2025-11-15
220	63	16	12	12	161.56	2025-11-15
221	63	25	6	6	171.1	2025-11-15
222	64	30	24	24	180.6	2025-11-15
223	64	20	6	6	67.24	2025-11-15
224	64	26	12	12	54.42	2025-11-15
225	64	24	48	48	35.99	2025-11-15
226	64	18	24	24	81.17	2025-11-15
227	65	11	18	18	195.04	2025-11-14
228	65	9	48	48	129.89	2025-11-14
229	66	29	18	18	46.38	2025-11-15
230	66	4	24	24	37.01	2025-11-15
231	66	1	6	6	12.24	2025-11-15
232	67	37	72	72	129.57	2025-11-15
233	67	4	12	12	37.77	2025-11-15
234	67	33	6	6	117.28	2025-11-15
235	67	32	6	6	124.18	2025-11-15
236	67	38	12	12	155.44	2025-11-15
237	68	5	24	24	111.03	2025-11-15
238	68	31	72	72	150.44	2025-11-15
239	69	1	6	6	11.87	2025-11-16
240	69	33	6	6	111.42	2025-11-16
241	70	26	12	12	55.53	2025-11-16
242	70	9	72	72	129.89	2025-11-16
243	71	31	72	72	150.44	2025-11-17
244	71	16	12	12	161.56	2025-11-17
245	71	39	6	6	32.52	2025-11-17
246	72	17	18	18	53.01	2025-11-16
247	72	22	18	18	165.43	2025-11-16
248	72	25	6	6	171.1	2025-11-16
249	73	31	72	72	150.44	2025-11-18
250	73	5	24	24	111.03	2025-11-18
251	73	20	18	18	68.61	2025-11-18
252	73	37	72	72	129.57	2025-11-18
253	73	29	6	6	47.33	2025-11-18
254	74	38	12	12	147.67	2025-11-17
255	74	17	6	6	50.36	2025-11-17
256	75	12	72	72	145.58	2025-11-18
257	75	33	6	6	117.28	2025-11-18
258	75	38	36	36	155.44	2025-11-18
259	75	19	24	24	153.58	2025-11-18
260	76	2	6	6	99.11	2025-11-17
261	76	5	48	48	105.48	2025-11-17
262	76	38	36	36	147.67	2025-11-17
263	77	20	6	6	65.18	2025-11-18
264	77	18	24	24	78.69	2025-11-18
265	77	12	24	24	138.3	2025-11-18
266	77	27	12	12	16.38	2025-11-18
267	78	25	6	6	167.68	2025-11-17
268	78	31	72	72	147.43	2025-11-17
269	78	27	12	12	16.9	2025-11-17
270	78	20	18	18	67.24	2025-11-17
271	78	2	18	18	102.24	2025-11-17
272	79	37	48	48	123.09	2025-11-18
273	79	6	48	48	146.84	2025-11-18
274	79	3	36	36	25.4	2025-11-18
275	79	20	6	6	65.18	2025-11-18
276	79	25	6	6	162.54	2025-11-18
277	80	4	36	36	37.77	2025-11-17
278	80	37	72	72	129.57	2025-11-17
279	80	5	24	24	111.03	2025-11-17
280	80	16	24	24	161.56	2025-11-17
281	81	18	24	24	82.83	2025-11-17
282	81	24	48	48	36.72	2025-11-17
283	82	4	12	12	35.88	2025-11-18
284	82	26	6	6	52.75	2025-11-18
285	82	12	24	24	138.3	2025-11-18
286	83	1	12	12	11.87	2025-11-19
287	83	20	6	6	65.18	2025-11-19
288	84	36	24	24	113.56	2025-11-18
289	84	25	6	6	162.54	2025-11-18
290	84	2	18	18	99.11	2025-11-18
291	84	39	12	12	30.89	2025-11-18
292	85	25	18	18	162.54	2025-11-19
293	85	23	24	3	44.56	2025-11-19
294	85	6	48	48	146.84	2025-11-19
295	86	17	12	12	53.01	2025-11-19
296	86	8	12	12	49.81	2025-11-19
297	86	13	12	12	97.54	2025-11-19
298	86	33	6	6	117.28	2025-11-19
299	86	5	72	72	111.03	2025-11-19
300	87	26	12	12	55.53	2025-11-18
301	87	24	48	48	36.72	2025-11-18
302	88	34	36	36	128.16	2025-11-18
303	88	4	36	36	35.88	2025-11-18
304	88	31	72	72	142.92	2025-11-18
305	89	33	18	18	114.93	2025-11-18
306	89	5	24	24	108.81	2025-11-18
307	89	16	36	36	158.33	2025-11-18
308	90	26	6	6	55.53	2025-11-19
309	90	9	24	24	129.89	2025-11-19
310	90	37	48	48	129.57	2025-11-19
311	91	16	36	36	161.56	2025-11-19
312	91	20	18	18	68.61	2025-11-19
313	92	26	6	6	55.53	2025-11-20
314	92	21	72	72	59.84	2025-11-20
315	92	6	72	72	154.57	2025-11-20
316	92	9	24	24	129.89	2025-11-20
317	92	16	12	12	161.56	2025-11-20
318	93	12	72	72	145.58	2025-11-20
319	93	2	12	12	104.33	2025-11-20
320	93	18	48	48	82.83	2025-11-20
321	94	29	6	6	47.33	2025-11-19
322	94	16	12	12	161.56	2025-11-19
323	94	5	48	48	111.03	2025-11-19
324	94	10	48	48	74.91	2025-11-19
325	94	8	18	18	49.81	2025-11-19
326	95	25	6	6	162.54	2025-11-21
327	95	6	48	48	146.84	2025-11-21
328	96	2	18	18	104.33	2025-11-21
329	96	30	48	48	184.29	2025-11-21
330	96	27	12	12	17.24	2025-11-21
331	97	17	18	18	53.01	2025-11-20
332	97	26	12	12	55.53	2025-11-20
333	98	11	18	18	195.04	2025-11-20
334	98	30	72	72	184.29	2025-11-20
335	98	34	12	12	134.91	2025-11-20
336	98	37	72	72	129.57	2025-11-20
337	98	33	6	6	117.28	2025-11-20
338	99	25	18	18	162.54	2025-11-20
339	99	20	18	18	65.18	2025-11-20
340	99	39	18	18	30.89	2025-11-20
341	99	30	48	48	175.08	2025-11-20
342	99	40	12	12	36.74	2025-11-20
343	100	9	48	48	129.89	2025-11-20
344	100	34	24	24	134.91	2025-11-20
345	100	38	36	36	155.44	2025-11-20
346	100	39	6	6	32.52	2025-11-20
347	100	16	24	24	161.56	2025-11-20
348	101	23	24	24	46.91	2025-11-21
349	101	12	72	72	145.58	2025-11-21
350	101	21	24	24	59.84	2025-11-21
351	101	6	24	24	154.57	2025-11-21
352	101	33	6	6	117.28	2025-11-21
353	102	16	36	36	158.33	2025-11-21
354	102	32	18	18	121.7	2025-11-21
355	102	27	24	24	16.9	2025-11-21
356	102	2	18	18	102.24	2025-11-21
357	103	6	72	72	154.57	2025-11-21
358	103	27	36	36	17.24	2025-11-21
359	104	12	24	24	138.3	2025-11-21
360	104	15	36	36	161.7	2025-11-21
361	104	24	24	24	34.88	2025-11-21
362	104	33	18	18	111.42	2025-11-21
363	105	37	72	72	129.57	2025-11-21
364	105	16	36	36	161.56	2025-11-21
365	106	31	24	24	150.44	2025-11-22
366	106	33	6	6	117.28	2025-11-22
367	107	30	48	48	180.6	2025-11-21
368	107	27	12	12	16.9	2025-11-21
369	107	6	48	48	151.48	2025-11-21
370	107	36	72	72	117.15	2025-11-21
371	108	33	6	6	111.42	2025-11-21
372	108	35	12	12	118.84	2025-11-21
373	108	38	24	24	147.67	2025-11-21
374	109	29	6	6	44.96	2025-11-21
375	109	37	48	48	123.09	2025-11-21
376	109	14	36	36	110.38	2025-11-21
377	109	18	24	24	78.69	2025-11-21
378	110	31	24	24	142.92	2025-11-21
379	110	16	36	36	153.48	2025-11-21
380	111	9	24	24	123.4	2025-11-21
381	111	2	12	12	99.11	2025-11-21
382	111	31	72	72	142.92	2025-11-21
383	111	24	48	48	34.88	2025-11-21
384	112	16	36	36	161.56	2025-11-21
385	112	27	36	36	17.24	2025-11-21
386	112	20	12	12	68.61	2025-11-21
387	112	37	72	72	129.57	2025-11-21
388	113	39	6	6	32.52	2025-11-21
389	113	33	18	18	117.28	2025-11-21
390	113	30	48	48	184.29	2025-11-21
391	114	24	24	24	34.88	2025-11-21
392	114	31	48	48	142.92	2025-11-21
393	114	14	12	12	110.38	2025-11-21
394	114	13	36	36	92.66	2025-11-21
395	114	17	12	12	50.36	2025-11-21
396	115	30	24	24	184.29	2025-11-23
397	115	23	24	24	46.91	2025-11-23
398	115	31	48	48	150.44	2025-11-23
399	116	37	72	72	126.98	2025-11-23
400	116	7	6	6	156.76	2025-11-23
401	117	26	6	6	55.53	2025-11-22
402	117	14	36	36	116.19	2025-11-22
403	117	24	48	48	36.72	2025-11-22
404	117	37	24	24	129.57	2025-11-22
405	117	27	24	24	17.24	2025-11-22
406	118	39	6	6	30.89	2025-11-23
407	118	5	72	72	105.48	2025-11-23
408	118	19	72	72	145.9	2025-11-23
409	118	29	12	12	44.96	2025-11-23
410	118	12	72	72	138.3	2025-11-23
411	119	25	18	18	171.1	2025-11-23
412	119	8	12	12	49.81	2025-11-23
413	120	31	72	72	147.43	2025-11-23
414	120	21	24	24	58.64	2025-11-23
415	121	2	6	6	102.24	2025-11-24
416	121	27	12	12	16.9	2025-11-24
417	121	26	12	12	54.42	2025-11-24
418	121	15	12	12	166.81	2025-11-24
419	122	5	72	72	111.03	2025-11-23
420	122	29	12	12	47.33	2025-11-23
421	123	33	18	18	117.28	2025-11-24
422	123	1	6	6	12.49	2025-11-24
423	124	33	12	12	117.28	2025-11-24
424	124	10	72	72	74.91	2025-11-24
425	124	21	72	72	59.84	2025-11-24
426	124	37	72	72	129.57	2025-11-24
427	125	32	6	6	124.18	2025-11-24
428	125	16	12	12	161.56	2025-11-24
429	125	5	72	72	111.03	2025-11-24
430	125	24	24	24	36.72	2025-11-24
431	125	3	24	24	26.74	2025-11-24
432	126	31	48	48	150.44	2025-11-25
433	126	27	24	24	17.24	2025-11-25
434	126	12	48	48	145.58	2025-11-25
435	126	38	36	36	155.44	2025-11-25
436	126	26	18	18	55.53	2025-11-25
437	127	13	24	24	92.66	2025-11-24
438	127	20	18	18	65.18	2025-11-24
439	128	12	72	72	145.58	2025-11-25
440	128	20	18	18	68.61	2025-11-25
441	129	25	18	18	167.68	2025-11-24
442	129	2	18	18	102.24	2025-11-24
443	129	30	24	24	180.6	2025-11-24
444	129	9	24	24	127.29	2025-11-24
445	129	24	24	24	35.99	2025-11-24
446	130	31	24	24	142.92	2025-11-24
447	130	16	12	12	153.48	2025-11-24
448	130	38	24	24	147.67	2025-11-24
449	130	39	12	12	30.89	2025-11-24
450	130	37	24	24	123.09	2025-11-24
451	131	1	6	6	12.24	2025-11-24
452	131	20	6	6	67.24	2025-11-24
453	131	31	24	24	147.43	2025-11-24
454	132	4	24	24	37.01	2025-11-25
455	132	22	18	18	162.12	2025-11-25
456	132	35	24	24	122.6	2025-11-25
457	132	31	72	72	147.43	2025-11-25
458	132	11	6	6	191.14	2025-11-25
459	133	12	48	48	142.67	2025-11-25
460	133	22	6	6	162.12	2025-11-25
461	133	10	72	72	73.41	2025-11-25
462	133	9	24	24	127.29	2025-11-25
463	134	9	24	24	123.4	2025-11-25
464	134	14	36	36	110.38	2025-11-25
465	134	31	48	48	142.92	2025-11-25
466	135	21	72	72	56.85	2025-11-25
467	135	31	24	24	142.92	2025-11-25
468	136	8	6	6	49.81	2025-11-25
469	136	33	6	6	117.28	2025-11-25
470	136	1	18	18	12.49	2025-11-25
471	137	17	12	12	50.36	2025-11-25
472	137	38	12	12	147.67	2025-11-25
473	138	9	24	24	129.89	2025-11-25
474	138	21	72	72	59.84	2025-11-25
475	138	26	12	12	55.53	2025-11-25
476	138	6	72	72	154.57	2025-11-25
477	138	5	72	72	111.03	2025-11-25
478	139	30	48	48	184.29	2025-11-25
479	139	32	18	18	124.18	2025-11-25
480	139	10	48	48	74.91	2025-11-25
481	139	9	48	48	129.89	2025-11-25
482	139	3	36	36	26.74	2025-11-25
483	140	26	6	6	55.53	2025-11-25
484	140	6	72	72	154.57	2025-11-25
485	140	2	18	18	104.33	2025-11-25
486	141	22	6	6	157.16	2025-11-26
487	141	19	48	48	145.9	2025-11-26
488	142	4	36	36	37.01	2025-11-26
489	142	15	12	12	166.81	2025-11-26
490	142	6	48	48	151.48	2025-11-26
491	142	8	6	6	48.81	2025-11-26
492	142	5	72	72	108.81	2025-11-26
493	143	33	6	6	117.28	2025-11-27
494	143	7	6	6	159.96	2025-11-27
495	143	16	36	36	161.56	2025-11-27
496	143	9	72	72	129.89	2025-11-27
497	144	4	12	12	37.01	2025-11-27
498	144	14	36	36	113.87	2025-11-27
499	144	24	72	72	35.99	2025-11-27
500	144	23	24	24	45.97	2025-11-27
501	145	14	36	36	116.19	2025-11-26
502	145	38	36	36	155.44	2025-11-26
503	145	32	12	12	124.18	2025-11-26
504	146	5	72	63	111.03	2025-11-26
505	146	33	6	6	117.28	2025-11-26
506	146	39	18	18	32.52	2025-11-26
507	146	30	48	48	184.29	2025-11-26
508	147	19	48	16	145.9	2025-11-27
509	147	23	12	12	44.56	2025-11-27
510	147	17	18	18	50.36	2025-11-27
511	147	3	24	24	25.4	2025-11-27
512	147	27	36	36	16.38	2025-11-27
513	148	31	24	24	150.44	2025-11-27
514	148	40	12	12	38.67	2025-11-27
515	148	25	18	2	171.1	2025-11-27
516	148	30	48	48	184.29	2025-11-27
517	149	30	48	48	184.29	2025-11-27
518	149	8	18	18	49.81	2025-11-27
519	149	4	36	36	37.77	2025-11-27
520	150	5	48	4	108.81	2025-11-29
521	150	12	24	24	142.67	2025-11-29
522	151	16	36	36	158.33	2025-11-28
523	151	38	36	36	152.33	2025-11-28
524	151	40	18	18	37.9	2025-11-28
525	151	8	18	18	48.81	2025-11-28
526	151	1	18	18	12.24	2025-11-28
527	152	10	24	24	74.91	2025-11-28
528	152	40	18	18	38.67	2025-11-28
529	152	38	12	12	155.44	2025-11-28
530	152	39	12	12	32.52	2025-11-28
531	152	37	72	72	129.57	2025-11-28
532	153	30	48	48	184.29	2025-11-28
533	153	16	24	24	161.56	2025-11-28
534	154	38	36	36	155.44	2025-11-28
535	154	30	48	48	184.29	2025-11-28
536	155	24	48	48	35.99	2025-11-28
537	155	8	18	18	48.81	2025-11-28
538	155	31	24	24	147.43	2025-11-28
539	156	14	24	24	113.87	2025-11-29
540	156	38	12	12	152.33	2025-11-29
541	156	31	48	48	147.43	2025-11-29
542	156	35	24	24	122.6	2025-11-29
543	156	10	24	24	73.41	2025-11-29
544	157	37	48	48	129.57	2025-11-29
545	157	16	12	12	161.56	2025-11-29
546	157	13	36	36	97.54	2025-11-29
547	157	6	24	24	154.57	2025-11-29
548	157	1	18	18	12.49	2025-11-29
549	158	31	72	72	150.44	2025-11-29
550	158	32	12	12	124.18	2025-11-29
551	158	1	12	12	12.49	2025-11-29
552	158	22	6	6	165.43	2025-11-29
553	158	16	36	36	161.56	2025-11-29
554	159	1	18	18	12.49	2025-11-29
555	159	36	72	72	119.54	2025-11-29
556	160	31	48	48	150.44	2025-11-29
557	160	37	48	48	129.57	2025-11-29
558	160	36	72	72	119.54	2025-11-29
559	160	39	18	18	32.52	2025-11-29
560	160	15	24	24	170.21	2025-11-29
561	161	12	24	24	145.58	2025-11-30
562	161	2	18	18	104.33	2025-11-30
563	161	39	18	18	32.52	2025-11-30
564	162	37	24	24	129.57	2025-11-29
565	162	39	12	12	32.52	2025-11-29
566	163	33	6	6	117.28	2025-11-29
567	163	38	24	24	155.44	2025-11-29
568	164	9	24	24	129.89	2025-11-29
569	164	29	18	18	47.33	2025-11-29
570	164	40	18	18	38.67	2025-11-29
571	165	1	18	18	12.24	2025-11-29
572	165	9	72	72	127.29	2025-11-29
573	165	40	12	12	37.9	2025-11-29
574	166	8	6	6	49.81	2025-11-30
575	166	27	12	12	17.24	2025-11-30
576	167	3	36	36	26.74	2025-12-01
577	167	16	24	24	161.56	2025-12-01
578	167	26	6	6	55.53	2025-12-01
579	167	22	6	6	165.43	2025-12-01
580	168	39	18	18	32.52	2025-12-01
581	168	20	6	6	68.61	2025-12-01
582	168	3	12	12	26.74	2025-12-01
583	168	26	6	6	55.53	2025-12-01
584	169	15	12	12	170.21	2025-12-01
585	169	24	48	48	36.72	2025-12-01
586	170	21	48	3	59.84	2025-12-01
587	170	7	18	18	159.96	2025-12-01
588	170	19	24	24	153.58	2025-12-01
589	170	29	12	12	47.33	2025-12-01
590	171	37	72	72	129.57	2025-12-01
591	171	2	18	18	104.33	2025-12-01
592	172	13	24	24	97.54	2025-12-01
593	172	12	48	48	145.58	2025-12-01
594	172	3	24	24	26.74	2025-12-01
595	172	20	6	6	68.61	2025-12-01
596	172	25	6	6	171.1	2025-12-01
597	173	24	48	48	35.99	2025-12-02
598	173	29	12	12	46.38	2025-12-02
599	173	30	24	24	180.6	2025-12-02
600	174	19	48	48	153.58	2025-12-02
601	174	37	24	24	129.57	2025-12-02
602	174	23	12	12	46.91	2025-12-02
603	174	16	24	24	161.56	2025-12-02
604	175	20	18	18	68.61	2025-12-02
605	175	5	24	24	111.03	2025-12-02
606	175	28	12	12	176.24	2025-12-02
607	176	37	48	48	126.98	2025-12-03
608	176	21	72	72	58.64	2025-12-03
609	176	12	72	72	142.67	2025-12-03
610	176	4	12	12	37.01	2025-12-03
611	176	31	24	24	147.43	2025-12-03
612	177	35	36	36	125.1	2025-12-04
613	177	37	72	72	129.57	2025-12-04
614	177	9	48	48	129.89	2025-12-04
615	177	34	12	12	134.91	2025-12-04
616	177	13	24	24	97.54	2025-12-04
617	178	28	36	36	176.24	2025-12-04
618	178	20	12	12	68.61	2025-12-04
619	178	38	36	36	155.44	2025-12-04
620	178	29	18	18	47.33	2025-12-04
621	178	27	24	24	17.24	2025-12-04
622	179	4	24	24	37.77	2025-12-04
623	179	20	12	12	68.61	2025-12-04
624	179	39	12	12	32.52	2025-12-04
625	179	38	24	24	155.44	2025-12-04
626	180	18	24	24	81.17	2025-12-04
627	180	36	72	72	117.15	2025-12-04
628	180	25	18	18	167.68	2025-12-04
629	180	40	18	18	37.9	2025-12-04
630	180	10	24	24	73.41	2025-12-04
631	181	37	48	48	129.57	2025-12-03
632	181	8	18	18	49.81	2025-12-03
633	182	29	12	12	47.33	2025-12-04
634	182	4	24	24	37.77	2025-12-04
635	182	38	24	24	155.44	2025-12-04
636	183	27	36	36	17.24	2025-12-03
637	183	4	36	36	37.77	2025-12-03
638	183	16	24	24	161.56	2025-12-03
639	183	38	36	36	155.44	2025-12-03
640	184	5	48	48	108.81	2025-12-03
641	184	9	72	72	127.29	2025-12-03
642	184	25	6	6	167.68	2025-12-03
643	184	14	36	36	113.87	2025-12-03
644	185	7	18	18	159.96	2025-12-04
645	185	12	48	48	145.58	2025-12-04
646	185	35	12	12	125.1	2025-12-04
647	185	29	12	12	47.33	2025-12-04
648	185	21	48	42	59.84	2025-12-04
649	186	26	6	6	55.53	2025-12-04
650	186	5	24	24	111.03	2025-12-04
651	187	29	12	12	47.33	2025-12-05
652	187	31	24	24	150.44	2025-12-05
653	187	22	6	6	165.43	2025-12-05
654	187	37	48	48	129.57	2025-12-05
655	188	30	24	24	184.29	2025-12-04
656	188	39	6	6	32.52	2025-12-04
657	188	20	12	12	68.61	2025-12-04
658	189	4	24	24	35.88	2025-12-04
659	189	25	6	5	162.54	2025-12-04
660	189	24	24	24	34.88	2025-12-04
661	189	18	48	48	78.69	2025-12-04
662	189	27	12	12	16.38	2025-12-04
663	190	2	6	6	99.11	2025-12-05
664	190	40	18	18	36.74	2025-12-05
665	191	2	12	12	104.33	2025-12-04
666	191	37	48	48	129.57	2025-12-04
667	191	23	36	36	46.91	2025-12-04
668	191	24	72	72	36.72	2025-12-04
669	192	23	36	36	46.91	2025-12-04
670	192	26	6	6	55.53	2025-12-04
671	192	1	6	6	12.49	2025-12-04
672	192	20	18	18	68.61	2025-12-04
673	193	5	72	72	111.03	2025-12-05
674	193	2	18	18	104.33	2025-12-05
675	194	18	72	72	82.83	2025-12-06
676	194	9	24	24	129.89	2025-12-06
677	194	40	12	12	38.67	2025-12-06
678	194	1	12	12	12.49	2025-12-06
679	194	25	12	12	171.1	2025-12-06
680	195	31	72	72	142.92	2025-12-06
681	195	37	24	24	123.09	2025-12-06
682	195	3	24	24	25.4	2025-12-06
683	195	35	36	36	118.84	2025-12-06
684	196	16	24	24	158.33	2025-12-05
685	196	38	12	12	152.33	2025-12-05
686	196	1	18	18	12.24	2025-12-05
687	196	36	72	72	117.15	2025-12-05
688	196	40	18	14	37.9	2025-12-05
689	197	8	12	12	47.32	2025-12-05
690	197	33	12	12	111.42	2025-12-05
691	197	24	72	72	34.88	2025-12-05
692	197	7	6	6	151.96	2025-12-05
693	198	3	12	12	26.74	2025-12-06
694	198	24	72	72	36.72	2025-12-06
695	198	20	18	18	68.61	2025-12-06
696	198	28	12	12	176.24	2025-12-06
697	199	33	12	12	114.93	2025-12-05
698	199	15	24	24	166.81	2025-12-05
699	199	13	36	36	95.59	2025-12-05
700	199	4	24	24	37.01	2025-12-05
701	200	20	6	6	68.61	2025-12-05
702	200	8	6	6	49.81	2025-12-05
703	200	38	12	12	155.44	2025-12-05
704	200	18	24	24	82.83	2025-12-05
705	201	33	12	12	114.93	2025-12-06
706	201	15	12	12	166.81	2025-12-06
707	201	25	6	6	167.68	2025-12-06
708	201	23	36	36	45.97	2025-12-06
709	202	4	12	12	37.77	2025-12-06
710	202	6	48	48	154.57	2025-12-06
711	202	17	6	6	53.01	2025-12-06
712	202	7	18	18	159.96	2025-12-06
713	203	38	36	36	147.67	2025-12-07
714	203	5	72	72	105.48	2025-12-07
715	203	12	72	72	138.3	2025-12-07
716	204	19	48	48	153.58	2025-12-06
717	204	6	72	72	154.57	2025-12-06
718	204	31	24	24	150.44	2025-12-06
719	204	38	24	24	155.44	2025-12-06
720	204	37	72	72	129.57	2025-12-06
721	205	3	24	24	26.21	2025-12-06
722	205	20	6	6	67.24	2025-12-06
723	205	6	24	24	151.48	2025-12-06
724	205	37	48	48	126.98	2025-12-06
725	206	16	36	36	161.56	2025-12-06
726	206	39	6	6	32.52	2025-12-06
727	206	26	12	12	55.53	2025-12-06
728	206	19	72	72	153.58	2025-12-06
729	207	39	12	12	32.52	2025-12-07
730	207	36	72	72	119.54	2025-12-07
731	207	13	12	12	97.54	2025-12-07
732	208	4	12	12	37.77	2025-12-08
733	208	22	18	18	165.43	2025-12-08
734	208	13	36	36	97.54	2025-12-08
735	208	5	48	48	111.03	2025-12-08
736	209	25	12	12	171.1	2025-12-08
737	209	1	12	12	12.49	2025-12-08
738	210	23	24	24	46.91	2025-12-08
739	210	39	18	18	32.52	2025-12-08
740	210	13	36	36	97.54	2025-12-08
741	211	21	72	0	59.84	\N
742	211	26	12	12	55.53	2025-12-08
743	212	5	48	48	111.03	2025-12-08
744	212	17	6	6	53.01	2025-12-08
745	212	15	12	12	170.21	2025-12-08
746	212	30	24	24	184.29	2025-12-08
747	212	2	12	12	104.33	2025-12-08
748	213	38	36	36	155.44	2025-12-08
749	213	11	6	6	195.04	2025-12-08
750	213	25	18	0	171.1	\N
751	213	16	36	36	161.56	2025-12-08
752	213	9	48	48	129.89	2025-12-08
753	214	23	36	36	46.91	2025-12-08
754	214	27	36	36	17.24	2025-12-08
755	214	4	24	24	37.77	2025-12-08
756	215	6	48	48	154.57	2025-12-08
757	215	30	72	72	184.29	2025-12-08
758	215	33	12	12	117.28	2025-12-08
759	215	16	24	24	161.56	2025-12-08
760	216	3	36	24	26.74	2025-12-09
761	216	33	18	18	117.28	2025-12-09
762	216	8	6	6	49.81	2025-12-09
763	216	38	12	12	155.44	2025-12-09
764	216	12	24	24	145.58	2025-12-09
765	217	26	18	18	55.53	2025-12-08
766	217	39	18	18	32.52	2025-12-08
767	218	27	24	24	16.38	2025-12-09
768	218	33	18	18	111.42	2025-12-09
769	219	4	24	24	37.77	2025-12-09
770	219	37	24	24	129.57	2025-12-09
771	220	25	18	0	162.54	\N
772	220	5	72	72	105.48	2025-12-09
773	220	21	24	0	56.85	\N
774	220	39	6	6	30.89	2025-12-09
775	220	36	24	24	113.56	2025-12-09
776	221	33	18	18	111.42	2025-12-10
777	221	20	12	12	65.18	2025-12-10
778	221	39	6	6	30.89	2025-12-10
779	221	4	36	36	35.88	2025-12-10
780	221	6	48	48	146.84	2025-12-10
781	222	14	36	3	113.87	2025-12-09
782	222	32	6	6	121.7	2025-12-09
783	222	27	24	24	16.9	2025-12-09
784	222	19	48	48	150.51	2025-12-09
785	222	4	36	36	37.01	2025-12-09
786	223	12	72	72	145.58	2025-12-09
787	223	29	18	18	47.33	2025-12-09
788	223	33	12	12	117.28	2025-12-09
789	223	16	36	36	161.56	2025-12-09
790	224	16	12	12	161.56	2025-12-10
791	224	2	18	18	104.33	2025-12-10
792	224	26	12	12	55.53	2025-12-10
793	224	20	6	6	68.61	2025-12-10
794	225	18	48	48	82.83	2025-12-10
795	225	39	12	12	32.52	2025-12-10
796	225	3	24	24	26.74	2025-12-10
797	225	19	48	48	153.58	2025-12-10
798	226	31	24	24	150.44	2025-12-10
799	226	12	24	24	145.58	2025-12-10
800	226	38	36	36	155.44	2025-12-10
801	227	19	48	48	150.51	2025-12-11
802	227	26	18	18	54.42	2025-12-11
803	227	15	24	24	166.81	2025-12-11
804	227	24	48	48	35.99	2025-12-11
805	227	29	6	6	46.38	2025-12-11
806	228	12	24	24	142.67	2025-12-10
807	228	17	6	6	51.95	2025-12-10
808	228	26	18	18	54.42	2025-12-10
809	228	31	48	48	147.43	2025-12-10
810	229	31	72	72	147.43	2025-12-11
811	229	30	48	48	180.6	2025-12-11
812	229	24	48	48	35.99	2025-12-11
813	230	35	12	12	125.1	2025-12-12
814	230	17	12	12	53.01	2025-12-12
815	230	8	18	18	49.81	2025-12-12
816	230	14	24	24	116.19	2025-12-12
817	231	38	36	36	152.33	2025-12-12
818	231	27	24	24	16.9	2025-12-12
819	231	2	18	18	102.24	2025-12-12
820	232	16	12	12	161.56	2025-12-11
821	232	9	72	72	129.89	2025-12-11
822	232	27	12	12	17.24	2025-12-11
823	232	37	72	72	129.57	2025-12-11
824	233	38	12	12	147.67	2025-12-12
825	233	12	48	48	138.3	2025-12-12
826	233	33	18	18	111.42	2025-12-12
827	233	20	12	9	65.18	2025-12-12
828	234	34	36	36	134.91	2025-12-11
829	234	23	36	36	46.91	2025-12-11
830	235	26	18	18	55.53	2025-12-13
831	235	12	72	72	145.58	2025-12-13
832	236	30	48	48	175.08	2025-12-13
833	236	18	48	48	78.69	2025-12-13
834	236	2	12	12	99.11	2025-12-13
835	236	31	72	72	142.92	2025-12-13
836	236	37	24	24	123.09	2025-12-13
837	237	26	12	12	52.75	2025-12-13
838	237	31	24	24	142.92	2025-12-13
839	238	5	72	72	111.03	2025-12-13
840	238	16	12	12	161.56	2025-12-13
841	238	30	48	32	184.29	2025-12-13
842	238	9	24	24	129.89	2025-12-13
843	238	21	72	72	59.84	2025-12-13
844	239	2	6	6	104.33	2025-12-12
845	239	24	24	24	36.72	2025-12-12
846	239	28	36	31	176.24	2025-12-12
847	239	25	18	18	171.1	2025-12-12
848	240	18	48	48	82.83	2025-12-12
849	240	31	48	48	150.44	2025-12-12
850	240	16	36	36	161.56	2025-12-12
851	240	38	12	12	155.44	2025-12-12
852	241	5	24	24	111.03	2025-12-12
853	241	16	24	24	161.56	2025-12-12
854	241	40	18	14	38.67	2025-12-12
855	241	12	48	48	145.58	2025-12-12
856	242	26	6	6	55.53	2025-12-12
857	242	18	48	48	82.83	2025-12-12
858	242	19	48	48	153.58	2025-12-12
859	242	23	36	28	46.91	2025-12-12
860	242	25	12	12	171.1	2025-12-12
861	243	27	12	12	17.24	2025-12-13
862	243	15	36	36	170.21	2025-12-13
863	244	37	72	72	129.57	2025-12-12
864	244	4	36	36	37.77	2025-12-12
865	244	26	12	12	55.53	2025-12-12
866	244	16	36	36	161.56	2025-12-12
867	244	8	6	6	49.81	2025-12-12
868	245	37	24	24	126.98	2025-12-12
869	245	12	48	48	142.67	2025-12-12
870	246	10	48	48	73.41	2025-12-14
871	246	33	12	12	114.93	2025-12-14
872	247	23	36	11	44.56	2025-12-13
873	247	14	24	24	110.38	2025-12-13
874	247	31	72	72	142.92	2025-12-13
875	247	8	18	18	47.32	2025-12-13
876	247	19	48	48	145.9	2025-12-13
877	248	24	48	48	36.72	2025-12-14
878	248	9	24	24	129.89	2025-12-14
879	249	19	48	28	153.58	2025-12-13
880	249	12	24	24	145.58	2025-12-13
881	249	17	6	6	53.01	2025-12-13
882	250	8	12	12	48.81	2025-12-15
883	250	5	24	24	108.81	2025-12-15
884	250	35	12	12	122.6	2025-12-15
885	250	7	6	6	156.76	2025-12-15
886	250	36	48	48	117.15	2025-12-15
887	251	31	48	48	147.43	2025-12-15
888	251	16	36	36	158.33	2025-12-15
889	251	22	18	18	162.12	2025-12-15
890	252	9	24	24	127.29	2025-12-15
891	252	3	24	24	26.21	2025-12-15
892	252	17	18	18	51.95	2025-12-15
893	252	14	36	36	113.87	2025-12-15
894	252	37	72	72	126.98	2025-12-15
895	253	26	18	18	54.42	2025-12-16
896	253	38	12	12	152.33	2025-12-16
897	254	10	72	72	74.91	2025-12-15
898	254	20	6	6	68.61	2025-12-15
899	254	12	24	24	145.58	2025-12-15
900	254	36	72	72	119.54	2025-12-15
901	255	27	36	36	17.24	2025-12-15
902	255	20	6	6	68.61	2025-12-15
903	255	26	6	6	55.53	2025-12-15
904	255	2	18	18	104.33	2025-12-15
905	255	37	24	24	129.57	2025-12-15
906	256	8	12	12	48.81	2025-12-15
907	256	5	24	24	108.81	2025-12-15
908	256	19	24	24	150.51	2025-12-15
909	257	25	6	6	171.1	2025-12-16
910	257	5	72	72	111.03	2025-12-16
911	257	37	72	72	129.57	2025-12-16
912	257	27	24	24	17.24	2025-12-16
913	257	1	18	18	12.49	2025-12-16
914	258	38	36	36	152.33	2025-12-15
915	258	33	18	18	114.93	2025-12-15
916	259	22	12	12	165.43	2025-12-15
917	259	16	12	12	161.56	2025-12-15
918	259	6	48	48	154.57	2025-12-15
919	259	26	6	6	55.53	2025-12-15
920	259	23	36	0	46.91	\N
921	260	8	6	6	49.81	2025-12-15
922	260	29	12	12	47.33	2025-12-15
923	260	3	12	12	26.74	2025-12-15
924	261	30	72	72	184.29	2025-12-17
925	261	31	72	72	150.44	2025-12-17
926	261	38	12	12	155.44	2025-12-17
927	261	17	18	18	53.01	2025-12-17
928	262	29	6	6	47.33	2025-12-16
929	262	26	6	6	55.53	2025-12-16
930	262	34	36	36	134.91	2025-12-16
931	262	37	24	24	129.57	2025-12-16
932	262	20	18	18	68.61	2025-12-16
933	263	28	12	12	176.24	2025-12-16
934	263	37	72	72	129.57	2025-12-16
935	263	9	48	48	129.89	2025-12-16
936	263	24	24	24	36.72	2025-12-16
937	263	16	36	36	161.56	2025-12-16
938	264	16	12	12	161.56	2025-12-16
939	264	18	24	24	82.83	2025-12-16
940	264	17	12	12	53.01	2025-12-16
941	264	29	12	12	47.33	2025-12-16
942	264	4	24	24	37.77	2025-12-16
943	265	2	12	12	104.33	2025-12-17
944	265	4	12	12	37.77	2025-12-17
945	266	13	36	36	97.54	2025-12-16
946	266	29	12	12	47.33	2025-12-16
947	267	4	12	12	37.77	2025-12-16
948	267	6	72	72	154.57	2025-12-16
949	267	40	18	0	38.67	\N
950	268	9	48	48	129.89	2025-12-16
951	268	33	18	18	117.28	2025-12-16
952	268	15	12	12	170.21	2025-12-16
953	268	26	6	6	55.53	2025-12-16
954	268	30	48	48	184.29	2025-12-16
955	269	25	12	12	171.1	2025-12-17
956	269	5	72	72	111.03	2025-12-17
957	269	10	72	24	74.91	2025-12-17
958	270	31	24	24	150.44	2025-12-17
959	270	38	12	12	155.44	2025-12-17
960	271	31	48	48	142.92	2025-12-17
961	271	8	12	12	47.32	2025-12-17
962	271	37	48	48	123.09	2025-12-17
963	271	15	36	36	161.7	2025-12-17
964	271	7	12	12	151.96	2025-12-17
965	272	23	36	36	44.56	2025-12-18
966	272	16	36	36	153.48	2025-12-18
967	272	20	12	12	65.18	2025-12-18
968	272	30	72	72	175.08	2025-12-18
969	273	36	48	48	113.56	2025-12-18
970	273	38	12	12	147.67	2025-12-18
971	273	8	18	18	47.32	2025-12-18
972	274	27	12	12	17.24	2025-12-17
973	274	12	24	24	145.58	2025-12-17
974	275	28	36	36	176.24	2025-12-17
975	275	26	18	18	55.53	2025-12-17
976	276	7	12	12	156.76	2025-12-17
977	276	4	24	24	37.01	2025-12-17
978	276	1	12	12	12.24	2025-12-17
979	276	18	48	48	81.17	2025-12-17
980	276	29	12	12	46.38	2025-12-17
981	277	15	12	12	161.7	2025-12-17
982	277	5	48	48	105.48	2025-12-17
983	277	13	24	24	92.66	2025-12-17
984	278	12	48	48	142.67	2025-12-18
985	278	2	6	6	102.24	2025-12-18
986	279	11	6	6	191.14	2025-12-18
987	279	9	72	72	127.29	2025-12-18
988	280	40	12	12	37.9	2025-12-18
989	280	29	18	18	46.38	2025-12-18
990	281	4	24	24	35.88	2025-12-19
991	281	31	24	24	142.92	2025-12-19
992	281	37	24	24	123.09	2025-12-19
993	281	25	6	6	162.54	2025-12-19
994	281	29	18	18	44.96	2025-12-19
995	282	12	24	24	138.3	2025-12-18
996	282	28	24	0	167.43	\N
997	283	33	6	6	114.93	2025-12-18
998	283	38	24	24	152.33	2025-12-18
999	284	6	48	48	154.57	2025-12-18
1000	284	24	48	48	36.72	2025-12-18
1001	284	25	18	14	171.1	2025-12-18
1002	284	20	6	6	68.61	2025-12-18
1003	284	31	24	24	150.44	2025-12-18
1004	285	29	12	12	47.33	2025-12-20
1005	285	6	24	24	154.57	2025-12-20
1006	285	26	18	18	55.53	2025-12-20
1007	285	37	72	72	129.57	2025-12-20
1008	285	16	36	36	161.56	2025-12-20
1009	286	16	36	36	161.56	2025-12-20
1010	286	3	24	24	26.74	2025-12-20
1011	287	10	72	72	73.41	2025-12-19
1012	287	25	12	12	167.68	2025-12-19
1013	287	16	12	12	158.33	2025-12-19
1014	287	33	12	12	114.93	2025-12-19
1015	287	20	18	18	67.24	2025-12-19
1016	288	31	72	72	150.44	2025-12-19
1017	288	24	24	24	36.72	2025-12-19
1018	288	37	48	48	129.57	2025-12-19
1019	288	6	24	24	154.57	2025-12-19
1020	288	12	72	72	145.58	2025-12-19
1021	289	32	6	6	121.7	2025-12-20
1022	289	37	48	48	126.98	2025-12-20
1023	289	1	6	6	12.24	2025-12-20
1024	289	4	12	12	37.01	2025-12-20
1025	290	6	24	24	146.84	2025-12-19
1026	290	32	18	18	117.97	2025-12-19
1027	291	26	6	6	54.42	2025-12-20
1028	291	17	6	6	51.95	2025-12-20
1029	291	20	18	18	67.24	2025-12-20
1030	292	37	48	48	129.57	2025-12-22
1031	292	31	72	72	150.44	2025-12-22
1032	292	20	18	18	68.61	2025-12-22
1033	292	1	18	18	12.49	2025-12-22
1034	293	4	36	36	37.77	2025-12-21
1035	293	23	24	0	46.91	\N
1036	293	24	24	24	36.72	2025-12-21
1037	294	16	36	36	161.56	2025-12-21
1038	294	39	6	6	32.52	2025-12-21
1039	294	25	12	0	171.1	\N
1040	294	30	24	24	184.29	2025-12-21
1041	295	30	24	24	180.6	2025-12-22
1042	295	19	48	48	150.51	2025-12-22
1043	295	3	36	25	26.21	2025-12-22
1044	296	31	24	24	150.44	2025-12-23
1045	296	33	12	12	117.28	2025-12-23
1046	296	18	24	24	82.83	2025-12-23
1047	296	37	48	48	129.57	2025-12-23
1048	296	1	6	6	12.49	2025-12-23
1049	297	24	72	72	36.72	2025-12-22
1050	297	28	36	36	176.24	2025-12-22
1051	297	4	12	12	37.77	2025-12-22
1052	297	13	36	36	97.54	2025-12-22
1053	298	13	12	12	97.54	2025-12-23
1054	298	5	72	53	111.03	2025-12-23
1055	298	12	48	48	145.58	2025-12-23
1056	298	33	6	6	117.28	2025-12-23
1057	299	22	12	12	157.16	2025-12-22
1058	299	17	12	12	50.36	2025-12-22
1059	300	38	12	12	155.44	2025-12-23
1060	300	15	12	12	170.21	2025-12-23
1061	300	1	12	12	12.49	2025-12-23
1062	300	30	72	72	184.29	2025-12-23
1063	300	12	72	72	145.58	2025-12-23
1064	301	12	72	72	138.3	2025-12-23
1065	301	33	12	9	111.42	2025-12-23
1066	302	26	12	12	52.75	2025-12-23
1067	302	39	6	6	30.89	2025-12-23
1068	303	38	24	24	147.67	2025-12-23
1069	303	13	12	12	92.66	2025-12-23
1070	303	24	24	24	34.88	2025-12-23
1071	304	6	24	24	151.48	2025-12-24
1072	304	24	72	72	35.99	2025-12-24
1073	304	8	18	18	48.81	2025-12-24
1074	304	5	24	24	108.81	2025-12-24
1075	304	31	48	48	147.43	2025-12-24
1076	305	16	24	24	153.48	2025-12-23
1077	305	33	18	18	111.42	2025-12-23
1078	306	17	18	8	50.36	2025-12-24
1079	306	24	48	48	34.88	2025-12-24
1080	307	30	72	72	184.29	2025-12-23
1081	307	4	12	12	37.77	2025-12-23
1082	308	25	6	6	171.1	2025-12-24
1083	308	27	12	12	17.24	2025-12-24
1084	308	39	12	12	32.52	2025-12-24
1085	309	18	72	72	81.17	2025-12-23
1086	309	3	24	24	26.21	2025-12-23
1087	309	31	48	48	147.43	2025-12-23
1088	310	39	12	12	32.52	2025-12-23
1089	310	2	6	6	104.33	2025-12-23
1090	310	32	12	12	124.18	2025-12-23
1091	310	16	36	36	161.56	2025-12-23
1092	310	6	24	24	154.57	2025-12-23
1093	311	29	12	12	44.96	2025-12-24
1094	311	33	12	12	111.42	2025-12-24
1095	311	2	18	18	99.11	2025-12-24
1096	311	26	12	12	52.75	2025-12-24
1097	311	10	48	48	71.16	2025-12-24
1098	312	39	18	18	32.52	2025-12-25
1099	312	26	6	6	55.53	2025-12-25
1100	312	34	36	36	134.91	2025-12-25
1101	313	28	36	36	172.72	2025-12-24
1102	313	13	24	24	95.59	2025-12-24
1103	313	5	48	48	108.81	2025-12-24
1104	313	17	12	12	51.95	2025-12-24
1105	314	4	12	12	37.77	2025-12-24
1106	314	21	48	48	59.84	2025-12-24
1107	314	12	24	24	145.58	2025-12-24
1108	314	27	36	36	17.24	2025-12-24
1109	314	26	6	6	55.53	2025-12-24
1110	315	9	24	24	129.89	2025-12-24
1111	315	6	72	72	154.57	2025-12-24
1112	316	38	24	24	147.67	2025-12-25
1113	316	12	48	48	138.3	2025-12-25
1114	316	26	12	12	52.75	2025-12-25
1115	316	18	48	48	78.69	2025-12-25
1116	317	18	48	48	81.17	2025-12-24
1117	317	23	12	0	45.97	\N
1118	317	26	6	6	54.42	2025-12-24
1119	317	4	12	12	37.01	2025-12-24
1120	318	24	24	24	36.72	2025-12-25
1121	318	26	6	6	55.53	2025-12-25
1122	318	34	24	22	134.91	2025-12-25
1123	319	37	24	24	123.09	2025-12-26
1124	319	27	24	24	16.38	2025-12-26
1125	319	26	12	12	52.75	2025-12-26
1126	319	33	18	18	111.42	2025-12-26
1127	320	12	48	48	138.3	2025-12-26
1128	320	29	18	18	44.96	2025-12-26
1129	321	4	12	12	37.01	2025-12-25
1130	321	40	6	6	37.9	2025-12-25
1131	322	25	12	12	167.68	2025-12-25
1132	322	22	12	12	162.12	2025-12-25
1133	322	12	72	72	142.67	2025-12-25
1134	322	26	6	6	54.42	2025-12-25
1135	322	21	24	24	58.64	2025-12-25
1136	323	24	72	72	36.72	2025-12-26
1137	323	39	12	12	32.52	2025-12-26
1138	323	37	72	72	129.57	2025-12-26
1139	323	5	48	48	111.03	2025-12-26
1140	324	10	48	48	71.16	2025-12-26
1141	324	6	24	24	146.84	2025-12-26
1142	324	31	72	72	142.92	2025-12-26
1143	325	28	12	12	167.43	2025-12-26
1144	325	32	12	7	117.97	2025-12-26
1145	325	6	24	24	146.84	2025-12-26
1146	326	25	12	12	171.1	2025-12-26
1147	326	15	24	24	170.21	2025-12-26
1148	326	4	12	12	37.77	2025-12-26
1149	327	15	24	24	166.81	2025-12-26
1150	327	39	6	6	31.87	2025-12-26
1151	327	9	48	48	127.29	2025-12-26
1152	328	9	24	24	129.89	2025-12-26
1153	328	27	24	24	17.24	2025-12-26
1154	329	4	24	24	37.77	2025-12-26
1155	329	28	36	36	176.24	2025-12-26
1156	329	8	12	12	49.81	2025-12-26
1157	330	20	12	12	67.24	2025-12-26
1158	330	18	48	48	81.17	2025-12-26
1159	330	4	12	12	37.01	2025-12-26
1160	331	11	18	18	195.04	2025-12-26
1161	331	10	48	48	74.91	2025-12-26
1162	331	26	12	12	55.53	2025-12-26
1163	331	5	24	24	111.03	2025-12-26
1164	331	12	48	48	145.58	2025-12-26
1165	332	39	18	18	30.89	2025-12-26
1166	332	27	24	24	16.38	2025-12-26
1167	333	35	24	24	122.6	2025-12-26
1168	333	39	12	12	31.87	2025-12-26
1169	334	30	24	24	184.29	2025-12-28
1170	334	15	24	24	170.21	2025-12-28
1171	334	16	24	24	161.56	2025-12-28
1172	334	38	12	12	155.44	2025-12-28
1173	335	33	6	6	111.42	2025-12-27
1174	335	28	12	12	167.43	2025-12-27
1175	335	39	12	12	30.89	2025-12-27
1176	336	18	48	48	78.69	2025-12-27
1177	336	2	6	6	99.11	2025-12-27
1178	337	25	6	6	171.1	2025-12-27
1179	337	20	18	18	68.61	2025-12-27
1180	337	17	18	18	53.01	2025-12-27
1181	338	25	6	6	171.1	2025-12-27
1182	338	4	12	12	37.77	2025-12-27
1183	338	23	12	0	46.91	\N
1184	338	19	72	72	153.58	2025-12-27
1185	338	38	12	12	155.44	2025-12-27
1186	339	40	6	6	37.9	2025-12-28
1187	339	20	18	18	67.24	2025-12-28
1188	339	35	24	24	122.6	2025-12-28
1189	339	13	12	12	95.59	2025-12-28
1190	339	23	24	24	45.97	2025-12-28
1191	340	38	36	36	147.67	2025-12-28
1192	340	32	18	18	117.97	2025-12-28
1193	341	2	18	18	104.33	2025-12-28
1194	341	38	24	24	155.44	2025-12-28
1195	342	16	12	12	153.48	2025-12-28
1196	342	18	48	48	78.69	2025-12-28
1197	342	31	48	48	142.92	2025-12-28
1198	342	32	6	0	117.97	\N
1199	343	37	72	72	126.98	2025-12-30
1200	343	12	48	48	142.67	2025-12-30
1201	344	40	12	12	38.67	2025-12-29
1202	344	38	24	24	155.44	2025-12-29
1203	344	36	72	72	119.54	2025-12-29
1204	344	7	18	18	159.96	2025-12-29
1205	344	2	18	18	104.33	2025-12-29
1206	345	12	48	48	138.3	2025-12-29
1207	345	23	12	12	44.56	2025-12-29
1208	345	6	24	24	146.84	2025-12-29
1209	345	31	24	24	142.92	2025-12-29
1210	345	9	24	24	123.4	2025-12-29
1211	346	39	18	18	32.52	2025-12-29
1212	346	12	24	24	145.58	2025-12-29
1213	346	29	12	12	47.33	2025-12-29
1214	347	31	48	48	150.44	2025-12-29
1215	347	39	12	12	32.52	2025-12-29
1216	347	12	48	48	145.58	2025-12-29
1217	347	16	36	36	161.56	2025-12-29
1218	348	13	24	24	95.59	2025-12-29
1219	348	7	18	18	156.76	2025-12-29
1220	348	18	72	72	81.17	2025-12-29
1221	348	20	6	6	67.24	2025-12-29
1222	349	9	48	48	123.4	2025-12-30
1223	349	11	6	6	185.29	2025-12-30
1224	349	4	12	12	35.88	2025-12-30
1225	349	27	36	36	16.38	2025-12-30
1226	350	31	48	48	150.44	2025-12-30
1227	350	20	12	12	68.61	2025-12-30
1228	350	35	36	36	125.1	2025-12-30
1229	351	25	12	12	167.68	2025-12-30
1230	351	12	24	24	142.67	2025-12-30
1231	352	7	6	6	159.96	2025-12-30
1232	352	40	18	18	38.67	2025-12-30
1233	352	38	12	12	155.44	2025-12-30
1234	352	18	72	72	82.83	2025-12-30
1235	353	25	6	6	162.54	2025-12-30
1236	353	10	72	72	71.16	2025-12-30
1237	354	6	72	72	151.48	2025-12-31
1238	354	21	48	48	58.64	2025-12-31
1239	355	26	6	6	55.53	2025-12-31
1240	355	9	48	48	129.89	2025-12-31
1241	355	33	12	12	117.28	2025-12-31
1242	355	16	24	24	161.56	2025-12-31
1243	355	3	12	12	26.74	2025-12-31
1244	356	2	12	12	104.33	2026-01-01
1245	356	6	48	48	154.57	2026-01-01
1246	357	2	6	6	104.33	2025-12-31
1247	357	24	48	48	36.72	2025-12-31
1248	357	11	18	18	195.04	2025-12-31
1249	358	19	24	24	145.9	2025-12-31
1250	358	33	18	18	111.42	2025-12-31
1251	359	15	12	12	166.81	2025-12-31
1252	359	5	72	72	108.81	2025-12-31
1253	359	38	36	36	152.33	2025-12-31
1254	359	35	24	24	122.6	2025-12-31
1255	359	31	24	24	147.43	2025-12-31
1256	360	20	18	18	68.61	2025-12-31
1257	360	29	6	6	47.33	2025-12-31
1258	361	16	36	36	158.33	2026-01-01
1259	361	21	72	72	58.64	2026-01-01
1260	361	31	72	72	147.43	2026-01-01
1261	361	6	24	24	151.48	2026-01-01
1262	362	6	24	24	146.84	2026-01-02
1263	362	25	12	12	162.54	2026-01-02
1264	362	22	12	12	157.16	2026-01-02
1265	363	37	72	72	129.57	2026-01-01
1266	363	25	12	12	171.1	2026-01-01
1267	364	9	48	48	129.89	2026-01-01
1268	364	20	6	6	68.61	2026-01-01
1269	364	12	48	48	145.58	2026-01-01
1270	365	26	6	6	55.53	2026-01-01
1271	365	31	24	24	150.44	2026-01-01
1272	365	3	36	36	26.74	2026-01-01
1273	366	16	24	24	153.48	2026-01-01
1274	366	8	12	12	47.32	2026-01-01
1275	366	27	36	36	16.38	2026-01-01
1276	366	18	24	24	78.69	2026-01-01
1277	367	4	36	36	35.88	2026-01-01
1278	367	20	6	0	65.18	\N
1279	368	9	72	72	129.89	2026-01-01
1280	368	23	12	12	46.91	2026-01-01
1281	368	27	24	24	17.24	2026-01-01
1282	368	1	12	12	12.49	2026-01-01
1283	368	37	72	72	129.57	2026-01-01
1284	369	19	72	72	150.51	2026-01-01
1285	369	6	24	24	151.48	2026-01-01
1286	369	15	36	36	166.81	2026-01-01
1287	369	4	36	36	37.01	2026-01-01
1288	370	26	6	6	52.75	2026-01-02
1289	370	2	6	6	99.11	2026-01-02
1290	370	6	48	48	146.84	2026-01-02
1291	370	31	48	48	142.92	2026-01-02
1292	371	32	18	18	124.18	2026-01-03
1293	371	33	6	6	117.28	2026-01-03
1294	371	16	12	12	161.56	2026-01-03
1295	371	22	12	12	165.43	2026-01-03
1296	372	35	12	12	122.6	2026-01-03
1297	372	20	6	6	67.24	2026-01-03
1298	372	17	18	18	51.95	2026-01-03
1299	373	31	24	24	150.44	2026-01-02
1300	373	18	24	24	82.83	2026-01-02
1301	373	9	24	24	129.89	2026-01-02
1302	373	37	24	24	129.57	2026-01-02
1303	374	10	24	24	71.16	2026-01-02
1304	374	1	12	12	11.87	2026-01-02
1305	374	22	6	6	157.16	2026-01-02
1306	375	13	24	24	92.66	2026-01-02
1307	375	23	36	36	44.56	2026-01-02
1308	376	12	24	24	138.3	2026-01-03
1309	376	6	72	72	146.84	2026-01-03
1310	376	18	24	24	78.69	2026-01-03
1311	376	4	12	12	35.88	2026-01-03
1312	377	21	48	48	59.84	2026-01-02
1313	377	22	6	6	165.43	2026-01-02
1314	377	6	48	48	154.57	2026-01-02
1315	377	9	48	48	129.89	2026-01-02
1316	378	8	18	18	49.81	2026-01-04
1317	378	12	72	72	145.58	2026-01-04
1318	379	2	6	6	99.11	2026-01-04
1319	379	1	6	6	11.87	2026-01-04
1320	379	5	72	72	105.48	2026-01-04
1321	379	29	6	6	44.96	2026-01-04
1322	380	32	6	6	124.18	2026-01-05
1323	380	8	12	12	49.81	2026-01-05
1324	380	15	24	24	170.21	2026-01-05
1325	381	2	6	6	104.33	2026-01-04
1326	381	23	24	24	46.91	2026-01-04
1327	381	12	48	48	145.58	2026-01-04
1328	381	37	48	48	129.57	2026-01-04
1329	382	6	24	24	151.48	2026-01-06
1330	382	16	36	36	158.33	2026-01-06
1331	382	9	24	24	127.29	2026-01-06
1332	382	20	12	12	67.24	2026-01-06
1333	383	5	72	72	111.03	2026-01-05
1334	383	16	24	24	161.56	2026-01-05
1335	383	24	24	24	36.72	2026-01-05
1336	383	31	72	72	150.44	2026-01-05
1337	384	37	24	24	129.57	2026-01-05
1338	384	12	72	72	145.58	2026-01-05
1339	384	16	36	36	161.56	2026-01-05
1340	385	23	12	12	45.97	2026-01-05
1341	385	8	18	18	48.81	2026-01-05
1342	385	2	12	12	102.24	2026-01-05
1343	385	33	18	18	114.93	2026-01-05
1344	386	22	18	18	162.12	2026-01-05
1345	386	25	12	0	167.68	\N
1346	386	37	72	72	126.98	2026-01-05
1347	386	12	24	24	142.67	2026-01-05
1348	387	14	36	36	116.19	2026-01-05
1349	387	19	72	72	153.58	2026-01-05
1350	387	38	24	24	155.44	2026-01-05
1351	387	25	6	6	171.1	2026-01-05
1352	388	24	48	48	34.88	2026-01-07
1353	388	5	24	24	105.48	2026-01-07
1354	388	16	36	36	153.48	2026-01-07
1355	388	22	18	18	157.16	2026-01-07
1356	388	23	36	36	44.56	2026-01-07
1357	389	31	48	48	150.44	2026-01-06
1358	389	27	12	12	17.24	2026-01-06
1359	389	23	36	36	46.91	2026-01-06
1360	390	12	24	24	142.67	2026-01-06
1361	390	5	24	24	108.81	2026-01-06
1362	390	37	72	72	126.98	2026-01-06
1363	391	11	12	12	195.04	2026-01-06
1364	391	22	18	18	165.43	2026-01-06
1365	392	6	72	72	151.48	2026-01-07
1366	392	25	6	6	167.68	2026-01-07
1367	393	25	12	12	171.1	2026-01-07
1368	393	4	36	36	37.77	2026-01-07
1369	393	27	24	24	17.24	2026-01-07
1370	393	16	36	36	161.56	2026-01-07
1371	393	30	72	72	184.29	2026-01-07
1372	394	33	12	12	117.28	2026-01-07
1373	394	31	24	24	150.44	2026-01-07
1374	394	37	48	48	129.57	2026-01-07
1375	394	21	24	24	59.84	2026-01-07
1376	394	38	36	36	155.44	2026-01-07
1377	395	15	24	24	170.21	2026-01-07
1378	395	39	12	12	32.52	2026-01-07
1379	395	32	6	6	124.18	2026-01-07
1380	395	37	24	24	129.57	2026-01-07
1381	396	2	6	6	102.24	2026-01-07
1382	396	18	72	72	81.17	2026-01-07
1383	397	4	36	36	35.88	2026-01-07
1384	397	38	12	12	147.67	2026-01-07
1385	397	33	18	18	111.42	2026-01-07
1386	397	26	18	18	52.75	2026-01-07
1387	398	21	72	72	58.64	2026-01-08
1388	398	5	72	72	108.81	2026-01-08
1389	398	22	6	6	162.12	2026-01-08
1390	399	18	72	72	82.83	2026-01-09
1391	399	21	48	48	59.84	2026-01-09
1392	399	24	48	48	36.72	2026-01-09
1393	399	33	6	6	117.28	2026-01-09
1394	400	12	72	72	145.58	2026-01-08
1395	400	31	48	48	150.44	2026-01-08
1396	400	4	36	36	37.77	2026-01-08
1397	400	36	24	24	119.54	2026-01-08
1398	400	23	36	36	46.91	2026-01-08
1399	401	37	24	24	126.98	2026-01-09
1400	401	20	18	18	67.24	2026-01-09
1401	401	39	18	18	31.87	2026-01-09
1402	401	21	72	48	58.64	2026-01-09
1403	401	33	18	18	114.93	2026-01-09
1404	402	1	12	12	12.49	2026-01-08
1405	402	14	36	36	116.19	2026-01-08
1406	402	38	12	12	155.44	2026-01-08
1407	402	25	18	0	171.1	\N
1408	402	29	18	18	47.33	2026-01-08
1409	403	9	24	24	127.29	2026-01-08
1410	403	25	12	0	167.68	\N
1411	403	16	12	12	158.33	2026-01-08
1412	404	6	24	24	154.57	2026-01-08
1413	404	24	24	24	36.72	2026-01-08
1414	405	29	18	18	47.33	2026-01-09
1415	405	12	24	24	145.58	2026-01-09
1416	405	31	72	72	150.44	2026-01-09
1417	405	24	24	24	36.72	2026-01-09
1418	405	9	48	48	129.89	2026-01-09
1419	406	10	72	72	73.41	2026-01-08
1420	406	25	18	18	167.68	2026-01-08
1421	407	19	48	48	150.51	2026-01-10
1422	407	38	12	12	152.33	2026-01-10
1423	407	8	12	12	48.81	2026-01-10
1424	407	22	18	18	162.12	2026-01-10
1425	408	27	12	12	16.38	2026-01-09
1426	408	9	48	48	123.4	2026-01-09
1427	409	24	24	24	35.99	2026-01-10
1428	409	17	12	12	51.95	2026-01-10
1429	409	25	6	6	167.68	2026-01-10
1430	410	38	12	12	152.33	2026-01-09
1431	410	37	48	48	126.98	2026-01-09
1432	410	25	6	6	167.68	2026-01-09
1433	410	33	18	18	114.93	2026-01-09
1434	411	31	48	48	147.43	2026-01-09
1435	411	37	48	48	126.98	2026-01-09
1436	411	39	18	18	31.87	2026-01-09
1437	411	7	18	18	156.76	2026-01-09
1438	411	12	24	24	142.67	2026-01-09
1439	412	29	6	6	47.33	2026-01-10
1440	412	6	72	72	154.57	2026-01-10
1441	412	22	6	6	165.43	2026-01-10
1442	413	9	48	48	129.89	2026-01-10
1443	413	33	18	18	117.28	2026-01-10
1444	414	26	12	12	54.42	2026-01-11
1445	414	38	36	36	152.33	2026-01-11
1446	415	17	18	18	50.36	2026-01-11
1447	415	37	72	72	123.09	2026-01-11
1448	415	6	72	72	146.84	2026-01-11
1449	415	16	24	24	153.48	2026-01-11
1450	416	18	24	24	78.69	2026-01-10
1451	416	17	18	18	50.36	2026-01-10
1452	416	25	6	6	162.54	2026-01-10
1453	416	7	6	6	151.96	2026-01-10
1454	416	38	12	12	147.67	2026-01-10
1455	417	23	36	36	44.56	2026-01-10
1456	417	26	6	6	52.75	2026-01-10
1457	417	39	6	6	30.89	2026-01-10
1458	417	16	36	36	153.48	2026-01-10
1459	418	25	18	18	167.68	2026-01-10
1460	418	12	24	24	142.67	2026-01-10
1461	419	9	72	72	129.89	2026-01-11
1462	419	30	48	48	184.29	2026-01-11
1463	419	38	24	24	155.44	2026-01-11
1464	419	33	18	18	117.28	2026-01-11
1465	419	13	12	12	97.54	2026-01-11
1466	420	31	48	48	150.44	2026-01-12
1467	420	3	36	36	26.74	2026-01-12
1468	420	33	12	12	117.28	2026-01-12
1469	420	8	18	18	49.81	2026-01-12
1470	420	40	6	6	38.67	2026-01-12
1471	421	39	6	6	31.87	2026-01-12
1472	421	25	12	12	167.68	2026-01-12
1473	421	37	72	72	126.98	2026-01-12
1474	422	9	72	72	127.29	2026-01-12
1475	422	36	72	72	117.15	2026-01-12
1476	422	28	36	36	172.72	2026-01-12
1477	423	4	24	24	35.88	2026-01-12
1478	423	29	18	18	44.96	2026-01-12
1479	424	6	72	72	154.57	2026-01-13
1480	424	31	72	72	150.44	2026-01-13
1481	424	30	24	24	184.29	2026-01-13
1482	424	39	18	18	32.52	2026-01-13
1483	425	40	18	18	36.74	2026-01-12
1484	425	29	18	18	44.96	2026-01-12
1485	425	16	24	24	153.48	2026-01-12
1486	425	31	24	24	142.92	2026-01-12
1487	426	16	24	24	161.56	2026-01-12
1488	426	30	72	72	184.29	2026-01-12
1489	427	38	36	36	147.67	2026-01-13
1490	427	1	6	6	11.87	2026-01-13
1491	427	23	36	0	44.56	\N
1492	427	29	6	6	44.96	2026-01-13
1493	427	37	24	24	123.09	2026-01-13
1494	428	17	12	12	53.01	2026-01-12
1495	428	13	24	24	97.54	2026-01-12
1496	428	12	72	72	145.58	2026-01-12
1497	428	4	24	24	37.77	2026-01-12
1498	428	14	24	24	116.19	2026-01-12
1499	429	22	18	16	165.43	2026-01-12
1500	429	37	48	48	129.57	2026-01-12
1501	429	26	18	18	55.53	2026-01-12
1502	429	14	36	36	116.19	2026-01-12
1503	430	33	6	6	114.93	2026-01-13
1504	430	39	6	6	31.87	2026-01-13
1505	431	17	18	18	50.36	2026-01-12
1506	431	24	72	72	34.88	2026-01-12
1507	431	6	72	72	146.84	2026-01-12
1508	431	20	6	6	65.18	2026-01-12
1509	431	37	24	24	123.09	2026-01-12
1510	432	39	12	12	30.89	2026-01-13
1511	432	3	36	36	25.4	2026-01-13
1512	432	14	12	12	110.38	2026-01-13
1513	432	33	6	6	111.42	2026-01-13
1514	433	24	72	72	36.72	2026-01-14
1515	433	15	36	36	170.21	2026-01-14
1516	434	26	12	12	55.53	2026-01-14
1517	434	40	18	18	38.67	2026-01-14
1518	434	32	18	18	124.18	2026-01-14
1519	434	31	72	72	150.44	2026-01-14
1520	434	24	72	72	36.72	2026-01-14
1521	435	4	12	12	37.77	2026-01-14
1522	435	38	36	36	155.44	2026-01-14
1523	436	18	48	48	81.17	2026-01-14
1524	436	37	24	24	126.98	2026-01-14
1525	436	22	18	0	162.12	\N
1526	436	12	72	72	142.67	2026-01-14
1527	437	39	12	12	32.52	2026-01-14
1528	437	3	36	36	26.74	2026-01-14
1529	437	16	36	36	161.56	2026-01-14
1530	437	4	12	12	37.77	2026-01-14
1531	437	37	48	48	129.57	2026-01-14
1532	438	37	48	48	126.98	2026-01-13
1533	438	14	12	12	113.87	2026-01-13
1534	438	2	6	6	102.24	2026-01-13
1535	438	31	72	72	147.43	2026-01-13
1536	438	4	24	24	37.01	2026-01-13
1537	439	10	24	24	74.91	2026-01-13
1538	439	23	24	24	46.91	2026-01-13
1539	440	5	72	72	111.03	2026-01-14
1540	440	18	72	72	82.83	2026-01-14
1541	440	12	48	48	145.58	2026-01-14
1542	440	16	36	36	161.56	2026-01-14
1543	441	12	72	72	145.58	2026-01-14
1544	441	33	12	12	117.28	2026-01-14
1545	441	8	12	12	49.81	2026-01-14
1546	441	26	18	18	55.53	2026-01-14
1547	442	29	18	18	47.33	2026-01-14
1548	442	8	6	6	49.81	2026-01-14
1549	442	12	72	72	145.58	2026-01-14
1550	443	6	72	72	154.57	2026-01-15
1551	443	36	48	48	119.54	2026-01-15
1552	444	12	72	72	145.58	2026-01-15
1553	444	5	24	24	111.03	2026-01-15
1554	444	38	12	12	155.44	2026-01-15
1555	445	9	48	48	123.4	2026-01-15
1556	445	11	6	6	185.29	2026-01-15
1557	445	27	24	24	16.38	2026-01-15
1558	446	24	72	72	36.72	2026-01-16
1559	446	31	48	48	150.44	2026-01-16
1560	447	39	6	6	32.52	2026-01-15
1561	447	18	24	24	82.83	2026-01-15
1562	447	9	72	72	129.89	2026-01-15
1563	447	30	48	48	184.29	2026-01-15
1564	447	12	72	72	145.58	2026-01-15
1565	448	14	36	36	113.87	2026-01-15
1566	448	2	18	18	102.24	2026-01-15
1567	449	30	24	24	180.6	2026-01-15
1568	449	17	6	6	51.95	2026-01-15
1569	449	37	72	72	126.98	2026-01-15
1570	449	9	24	24	127.29	2026-01-15
1571	450	30	48	48	184.29	2026-01-15
1572	450	12	48	48	145.58	2026-01-15
1573	451	25	12	12	171.1	2026-01-17
1574	451	35	24	24	125.1	2026-01-17
1575	452	12	48	48	145.58	2026-01-17
1576	452	9	48	48	129.89	2026-01-17
1577	452	13	12	12	97.54	2026-01-17
1578	452	24	72	72	36.72	2026-01-17
1579	453	22	6	6	157.16	2026-01-16
1580	453	20	18	18	65.18	2026-01-16
1581	453	8	12	12	47.32	2026-01-16
1582	453	23	36	36	44.56	2026-01-16
1583	454	37	48	48	129.57	2026-01-17
1584	454	12	72	72	145.58	2026-01-17
1585	454	36	48	48	119.54	2026-01-17
1586	454	16	36	36	161.56	2026-01-17
1587	454	1	18	18	12.49	2026-01-17
1588	455	29	6	6	47.33	2026-01-16
1589	455	7	12	12	159.96	2026-01-16
1590	456	18	24	24	82.83	2026-01-16
1591	456	13	24	24	97.54	2026-01-16
1592	457	37	24	24	126.98	2026-01-18
1593	457	2	12	12	102.24	2026-01-18
1594	458	1	12	12	12.49	2026-01-18
1595	458	21	72	72	59.84	2026-01-18
1596	458	19	72	72	153.58	2026-01-18
1597	458	9	24	24	129.89	2026-01-18
1598	459	21	72	0	56.85	\N
1599	459	20	18	18	65.18	2026-01-18
1600	459	37	24	24	123.09	2026-01-18
1601	459	31	24	24	142.92	2026-01-18
1602	460	11	18	18	195.04	2026-01-18
1603	460	2	6	6	104.33	2026-01-18
1604	461	31	24	24	150.44	2026-01-19
1605	461	2	6	6	104.33	2026-01-19
1606	461	16	12	12	161.56	2026-01-19
1607	462	29	6	6	46.38	2026-01-19
1608	462	5	24	24	108.81	2026-01-19
1609	462	26	12	12	54.42	2026-01-19
1610	462	21	72	0	58.64	\N
1611	462	12	48	48	142.67	2026-01-19
1612	463	5	72	72	108.81	2026-01-20
1613	463	4	36	36	37.01	2026-01-20
1614	463	17	12	12	51.95	2026-01-20
1615	463	2	12	12	102.24	2026-01-20
1616	464	31	72	72	147.43	2026-01-19
1617	464	38	36	36	152.33	2026-01-19
1618	464	11	6	6	191.14	2026-01-19
1619	464	7	18	18	156.76	2026-01-19
1620	464	26	18	18	54.42	2026-01-19
1621	465	11	6	6	185.29	2026-01-19
1622	465	26	12	12	52.75	2026-01-19
1623	465	4	24	24	35.88	2026-01-19
1624	465	33	18	4	111.42	2026-01-19
1625	466	27	12	12	17.24	2026-01-19
1626	466	5	48	48	111.03	2026-01-19
1627	466	9	72	72	129.89	2026-01-19
1628	466	3	36	36	26.74	2026-01-19
1629	467	3	36	36	26.74	2026-01-19
1630	467	10	72	72	74.91	2026-01-19
1631	467	4	24	24	37.77	2026-01-19
1632	468	38	36	36	152.33	2026-01-19
1633	468	2	6	6	102.24	2026-01-19
1634	468	37	72	72	126.98	2026-01-19
1635	469	20	6	6	68.61	2026-01-19
1636	469	31	72	72	150.44	2026-01-19
1637	470	10	24	24	74.91	2026-01-19
1638	470	38	12	12	155.44	2026-01-19
1639	470	29	12	12	47.33	2026-01-19
1640	470	18	72	72	82.83	2026-01-19
1641	471	26	12	12	55.53	2026-01-19
1642	471	24	48	48	36.72	2026-01-19
1643	471	2	18	18	104.33	2026-01-19
1644	471	17	18	18	53.01	2026-01-19
1645	471	37	24	24	129.57	2026-01-19
1646	472	6	72	72	154.57	2026-01-20
1647	472	9	24	24	129.89	2026-01-20
1648	472	4	36	36	37.77	2026-01-20
1649	473	39	12	12	30.89	2026-01-20
1650	473	33	18	0	111.42	\N
1651	473	24	72	72	34.88	2026-01-20
1652	474	10	24	24	73.41	2026-01-20
1653	474	12	72	72	142.67	2026-01-20
1654	475	26	6	6	52.75	2026-01-20
1655	475	1	18	18	11.87	2026-01-20
1656	476	33	18	0	117.28	\N
1657	476	30	48	48	184.29	2026-01-20
1658	477	18	24	18	82.83	2026-01-20
1659	477	4	36	36	37.77	2026-01-20
1660	478	31	72	72	142.92	2026-01-20
1661	478	29	6	6	44.96	2026-01-20
1662	479	30	24	24	180.6	2026-01-21
1663	479	23	36	0	45.97	\N
1664	479	38	36	36	152.33	2026-01-21
1665	479	16	24	24	158.33	2026-01-21
1666	480	14	36	0	116.19	\N
1667	480	31	48	48	150.44	2026-01-21
1668	480	36	48	48	119.54	2026-01-21
1669	480	4	36	36	37.77	2026-01-21
1670	480	12	24	24	145.58	2026-01-21
1671	481	4	36	36	35.88	2026-01-20
1672	481	25	18	6	162.54	2026-01-20
1673	481	26	12	12	52.75	2026-01-20
1674	481	37	48	48	123.09	2026-01-20
1675	481	22	18	18	157.16	2026-01-20
1676	482	22	6	6	165.43	2026-01-20
1677	482	33	6	6	117.28	2026-01-20
1678	482	4	24	24	37.77	2026-01-20
1679	482	25	6	0	171.1	\N
1680	482	16	24	24	161.56	2026-01-20
1681	483	33	6	6	114.93	2026-01-20
1682	483	5	48	48	108.81	2026-01-20
1683	483	40	12	12	37.9	2026-01-20
1684	483	26	12	12	54.42	2026-01-20
1685	484	23	12	0	46.91	\N
1686	484	27	36	36	17.24	2026-01-20
1687	484	20	6	6	68.61	2026-01-20
1688	484	9	24	24	129.89	2026-01-20
1689	485	12	24	24	145.58	2026-01-21
1690	485	31	72	72	150.44	2026-01-21
1691	485	8	18	18	49.81	2026-01-21
1692	485	39	18	18	32.52	2026-01-21
1693	486	37	24	24	129.57	2026-01-21
1694	486	13	24	24	97.54	2026-01-21
1695	486	31	48	48	150.44	2026-01-21
1696	486	25	12	12	171.1	2026-01-21
1697	486	27	12	12	17.24	2026-01-21
1698	487	9	48	48	129.89	2026-01-22
1699	487	6	24	24	154.57	2026-01-22
1700	487	37	24	24	129.57	2026-01-22
1701	487	15	36	36	170.21	2026-01-22
1702	487	38	36	36	155.44	2026-01-22
1703	488	17	18	18	51.95	2026-01-21
1704	488	5	24	24	108.81	2026-01-21
1705	488	38	36	36	152.33	2026-01-21
1706	488	31	72	72	147.43	2026-01-21
1707	488	12	72	72	142.67	2026-01-21
1708	489	18	48	48	82.83	2026-01-21
1709	489	1	6	6	12.49	2026-01-21
1710	489	25	18	0	171.1	\N
1711	489	9	48	48	129.89	2026-01-21
1712	489	28	36	36	176.24	2026-01-21
1713	490	6	48	48	154.57	2026-01-21
1714	490	33	6	6	117.28	2026-01-21
1715	490	39	18	18	32.52	2026-01-21
1716	491	22	18	18	165.43	2026-01-21
1717	491	33	12	12	117.28	2026-01-21
1718	491	31	72	72	150.44	2026-01-21
1719	492	16	36	36	161.56	2026-01-21
1720	492	33	18	18	117.28	2026-01-21
1721	492	29	6	6	47.33	2026-01-21
1722	492	31	72	72	150.44	2026-01-21
1723	492	12	48	48	145.58	2026-01-21
1724	493	31	24	24	150.44	2026-01-23
1725	493	17	18	18	53.01	2026-01-23
1726	493	27	12	12	17.24	2026-01-23
1727	493	2	12	12	104.33	2026-01-23
1728	494	31	24	24	142.92	2026-01-22
1729	494	29	12	12	44.96	2026-01-22
1730	494	4	12	12	35.88	2026-01-22
1731	494	2	12	12	99.11	2026-01-22
1732	495	1	12	12	12.24	2026-01-22
1733	495	36	24	24	117.15	2026-01-22
1734	495	25	18	18	167.68	2026-01-22
1735	496	11	12	12	185.29	2026-01-22
1736	496	29	12	12	44.96	2026-01-22
1737	496	31	48	48	142.92	2026-01-22
1738	496	23	24	0	44.56	\N
1739	496	12	48	48	138.3	2026-01-22
1740	497	16	36	36	161.56	2026-01-22
1741	497	31	48	48	150.44	2026-01-22
1742	497	39	6	6	32.52	2026-01-22
1743	497	26	18	18	55.53	2026-01-22
1744	497	38	24	24	155.44	2026-01-22
1745	498	4	12	12	37.77	2026-01-22
1746	498	37	48	48	129.57	2026-01-22
1747	498	38	36	36	155.44	2026-01-22
1748	498	20	18	18	68.61	2026-01-22
1749	498	2	12	12	104.33	2026-01-22
1750	499	34	12	12	132.21	2026-01-24
1751	499	1	12	12	12.24	2026-01-24
1752	499	15	12	12	166.81	2026-01-24
1753	499	29	6	6	46.38	2026-01-24
1754	499	12	24	24	142.67	2026-01-24
1755	500	16	36	36	161.56	2026-01-24
1756	500	23	24	24	46.91	2026-01-24
1757	500	35	24	24	125.1	2026-01-24
1758	500	40	6	6	38.67	2026-01-24
1759	501	37	72	72	129.57	2026-01-23
1760	501	15	36	36	170.21	2026-01-23
1761	501	39	12	12	32.52	2026-01-23
1762	502	8	12	12	47.32	2026-01-23
1763	502	29	18	18	44.96	2026-01-23
1764	502	12	24	24	138.3	2026-01-23
1765	502	38	36	1	147.67	2026-01-23
1766	503	38	12	12	155.44	2026-01-24
1767	503	6	24	24	154.57	2026-01-24
1768	503	40	12	12	38.67	2026-01-24
1769	503	8	18	18	49.81	2026-01-24
1770	503	4	12	12	37.77	2026-01-24
1771	504	5	72	72	111.03	2026-01-24
1772	504	30	72	72	184.29	2026-01-24
1773	505	32	12	12	121.7	2026-01-24
1774	505	16	36	36	158.33	2026-01-24
1775	506	2	18	18	102.24	2026-01-25
1776	506	37	24	24	126.98	2026-01-25
1777	506	20	12	12	67.24	2026-01-25
1778	507	39	6	6	32.52	2026-01-26
1779	507	12	72	72	145.58	2026-01-26
1780	508	29	6	6	47.33	2026-01-25
1781	508	27	36	36	17.24	2026-01-25
1782	509	9	72	72	127.29	2026-01-25
1783	509	16	36	36	158.33	2026-01-25
1784	510	9	48	48	127.29	2026-01-26
1785	510	5	48	48	108.81	2026-01-26
1786	510	29	6	6	46.38	2026-01-26
1787	510	34	36	36	132.21	2026-01-26
1788	510	2	6	6	102.24	2026-01-26
1789	511	16	36	36	158.33	2026-01-27
1790	511	23	24	24	45.97	2026-01-27
1791	512	16	36	36	161.56	2026-01-26
1792	512	6	24	24	154.57	2026-01-26
1793	513	13	36	36	92.66	2026-01-27
1794	513	14	24	24	110.38	2026-01-27
1795	513	33	6	6	111.42	2026-01-27
1796	513	25	12	0	162.54	\N
1797	513	22	18	18	157.16	2026-01-27
1798	514	34	12	12	128.16	2026-01-26
1799	514	12	48	25	138.3	2026-01-26
1800	514	29	6	6	44.96	2026-01-26
1801	514	37	24	24	123.09	2026-01-26
1802	515	17	18	18	51.95	2026-01-26
1803	515	21	48	48	58.64	2026-01-26
1804	515	31	48	48	147.43	2026-01-26
1805	515	27	36	36	16.9	2026-01-26
1806	516	1	6	6	12.49	2026-01-26
1807	516	10	48	48	74.91	2026-01-26
1808	516	8	12	12	49.81	2026-01-26
1809	517	9	24	24	129.89	2026-01-26
1810	517	18	48	48	82.83	2026-01-26
1811	518	23	12	0	46.91	\N
1812	518	31	24	24	150.44	2026-01-26
1813	519	25	18	0	167.68	\N
1814	519	16	36	36	158.33	2026-01-27
1815	519	30	72	72	180.6	2026-01-27
1816	520	31	72	72	150.44	2026-01-27
1817	520	28	36	36	176.24	2026-01-27
1818	520	16	12	12	161.56	2026-01-27
1819	520	1	12	12	12.49	2026-01-27
1820	521	21	72	72	59.84	2026-01-26
1821	521	22	12	12	165.43	2026-01-26
1822	521	16	36	36	161.56	2026-01-26
1823	521	2	6	6	104.33	2026-01-26
1824	522	31	72	72	150.44	2026-01-26
1825	522	24	24	24	36.72	2026-01-26
1826	522	6	48	48	154.57	2026-01-26
1827	523	39	12	12	32.52	2026-01-28
1828	523	8	18	18	49.81	2026-01-28
1829	523	23	36	36	46.91	2026-01-28
1830	524	16	24	24	161.56	2026-01-27
1831	524	14	36	36	116.19	2026-01-27
1832	524	38	12	12	155.44	2026-01-27
1833	525	6	72	72	154.57	2026-01-27
1834	525	15	24	24	170.21	2026-01-27
1835	525	9	48	48	129.89	2026-01-27
1836	525	16	12	12	161.56	2026-01-27
1837	526	23	24	24	46.91	2026-01-27
1838	526	16	36	36	161.56	2026-01-27
1839	526	4	12	12	37.77	2026-01-27
1840	527	37	72	72	129.57	2026-01-27
1841	527	25	6	6	171.1	2026-01-27
1842	527	3	36	24	26.74	2026-01-27
1843	528	19	72	72	153.58	2026-01-27
1844	528	6	48	48	154.57	2026-01-27
1845	529	3	24	0	26.21	\N
1846	529	12	24	24	142.67	2026-01-27
1847	529	4	36	36	37.01	2026-01-27
1848	529	2	6	6	102.24	2026-01-27
1849	530	18	72	40	81.17	2026-01-28
1850	530	21	24	24	58.64	2026-01-28
1851	531	17	6	6	50.36	2026-01-27
1852	531	22	12	12	157.16	2026-01-27
1853	531	30	48	48	175.08	2026-01-27
1854	531	9	48	48	123.4	2026-01-27
1855	531	31	24	24	142.92	2026-01-27
1856	532	15	24	24	166.81	2026-01-27
1857	532	9	72	72	127.29	2026-01-27
1858	532	14	12	12	113.87	2026-01-27
1859	533	17	12	12	53.01	2026-01-27
1860	533	23	36	36	46.91	2026-01-27
1861	533	34	12	12	134.91	2026-01-27
1862	533	18	48	0	82.83	\N
1863	533	27	24	24	17.24	2026-01-27
1864	534	16	12	12	158.33	2026-01-27
1865	534	9	24	24	127.29	2026-01-27
1866	534	12	72	72	142.67	2026-01-27
1867	535	22	18	18	165.43	2026-01-28
1868	535	10	24	24	74.91	2026-01-28
1869	535	34	12	12	134.91	2026-01-28
1870	536	24	24	24	34.88	2026-01-28
1871	536	20	18	18	65.18	2026-01-28
1872	536	5	48	48	105.48	2026-01-28
1873	536	22	18	18	157.16	2026-01-28
1874	537	25	6	6	171.1	2026-01-28
1875	537	8	6	6	49.81	2026-01-28
1876	537	36	48	48	119.54	2026-01-28
1877	538	19	24	24	153.58	2026-01-28
1878	538	27	12	12	17.24	2026-01-28
1879	538	13	36	36	97.54	2026-01-28
1880	538	6	24	24	154.57	2026-01-28
1881	538	24	48	48	36.72	2026-01-28
1882	539	31	48	48	147.43	2026-01-29
1883	539	38	36	36	152.33	2026-01-29
1884	539	24	72	72	35.99	2026-01-29
1885	539	21	48	48	58.64	2026-01-29
1886	540	36	48	48	119.54	2026-01-30
1887	540	12	72	72	145.58	2026-01-30
1888	540	30	24	24	184.29	2026-01-30
1889	540	19	24	24	153.58	2026-01-30
1890	541	24	24	24	36.72	2026-01-29
1891	541	39	12	12	32.52	2026-01-29
1892	541	38	12	12	155.44	2026-01-29
1893	541	29	12	12	47.33	2026-01-29
1894	541	33	18	18	117.28	2026-01-29
1895	542	17	12	12	51.95	2026-01-30
1896	542	31	72	72	147.43	2026-01-30
1897	542	4	36	36	37.01	2026-01-30
1898	543	4	24	24	37.77	2026-01-31
1899	543	38	36	36	155.44	2026-01-31
1900	543	23	24	24	46.91	2026-01-31
1901	544	31	48	48	142.92	2026-01-30
1902	544	9	72	72	123.4	2026-01-30
1903	544	2	6	6	99.11	2026-01-30
1904	545	37	72	72	126.98	2026-01-31
1905	545	4	36	36	37.01	2026-01-31
1906	545	23	36	36	45.97	2026-01-31
1907	546	18	24	24	82.83	2026-01-30
1908	546	16	12	12	161.56	2026-01-30
1909	546	33	12	12	117.28	2026-01-30
1910	547	7	12	12	151.96	2026-01-30
1911	547	2	12	12	99.11	2026-01-30
1912	547	25	12	0	162.54	\N
1913	547	4	12	12	35.88	2026-01-30
1914	547	37	72	72	123.09	2026-01-30
1915	548	19	48	48	153.58	2026-01-31
1916	548	6	24	24	154.57	2026-01-31
1917	548	29	12	12	47.33	2026-01-31
1918	548	35	24	24	125.1	2026-01-31
1919	549	31	24	24	147.43	2026-01-31
1920	549	16	36	36	158.33	2026-01-31
1921	550	12	24	24	138.3	2026-02-01
1922	550	17	6	6	50.36	2026-02-01
1923	550	7	18	18	151.96	2026-02-01
1924	551	26	6	6	55.53	2026-02-02
1925	551	15	24	24	170.21	2026-02-02
1926	551	4	24	24	37.77	2026-02-02
1927	552	18	72	72	82.83	2026-02-02
1928	552	27	36	36	17.24	2026-02-02
1929	552	2	12	12	104.33	2026-02-02
1930	552	13	36	36	97.54	2026-02-02
1931	553	12	24	24	145.58	2026-02-02
1932	553	25	12	0	171.1	\N
1933	554	12	48	48	145.58	2026-02-02
1934	554	29	12	12	47.33	2026-02-02
1935	555	26	18	18	55.53	2026-02-02
1936	555	31	24	24	150.44	2026-02-02
1937	555	36	48	48	119.54	2026-02-02
1938	555	21	72	72	59.84	2026-02-02
1939	555	12	24	24	145.58	2026-02-02
1940	556	36	48	48	117.15	2026-02-02
1941	556	15	24	24	166.81	2026-02-02
1942	556	16	36	36	158.33	2026-02-02
1943	557	24	24	24	35.99	2026-02-02
1944	557	29	18	18	46.38	2026-02-02
1945	557	37	72	72	126.98	2026-02-02
1946	557	15	36	36	166.81	2026-02-02
1947	557	12	48	48	142.67	2026-02-02
1948	558	10	48	48	74.91	2026-02-03
1949	558	37	48	48	129.57	2026-02-03
1950	558	9	24	24	129.89	2026-02-03
1951	559	17	18	18	53.01	2026-02-02
1952	559	6	72	72	154.57	2026-02-02
1953	559	13	12	12	97.54	2026-02-02
1954	559	2	18	18	104.33	2026-02-02
1955	560	36	72	72	119.54	2026-02-02
1956	560	25	6	6	171.1	2026-02-02
1957	560	6	24	24	154.57	2026-02-02
1958	561	23	12	12	46.91	2026-02-03
1959	561	34	36	9	134.91	2026-02-03
1960	562	26	6	6	52.75	2026-02-04
1961	562	37	72	72	123.09	2026-02-04
1962	562	40	12	12	36.74	2026-02-04
1963	563	9	48	48	123.4	2026-02-03
1964	563	33	18	18	111.42	2026-02-03
1965	563	38	24	24	147.67	2026-02-03
1966	564	3	12	12	26.74	2026-02-04
1967	564	1	12	12	12.49	2026-02-04
1968	565	16	12	12	161.56	2026-02-03
1969	565	12	24	24	145.58	2026-02-03
1970	565	39	6	6	32.52	2026-02-03
1971	566	12	72	72	145.58	2026-02-04
1972	566	4	12	12	37.77	2026-02-04
1973	566	36	24	24	119.54	2026-02-04
1974	567	38	12	12	155.44	2026-02-03
1975	567	37	24	24	129.57	2026-02-03
1976	567	33	18	18	117.28	2026-02-03
1977	567	26	6	6	55.53	2026-02-03
1978	567	23	24	24	46.91	2026-02-03
1979	568	13	24	24	92.66	2026-02-04
1980	568	40	6	6	36.74	2026-02-04
1981	568	2	12	12	99.11	2026-02-04
1982	569	4	36	36	37.01	2026-02-03
1983	569	20	6	6	67.24	2026-02-03
1984	570	24	24	24	36.72	2026-02-04
1985	570	29	12	12	47.33	2026-02-04
1986	570	38	36	36	155.44	2026-02-04
1987	571	37	24	24	129.57	2026-02-05
1988	571	38	36	36	155.44	2026-02-05
1989	571	15	36	36	170.21	2026-02-05
1990	571	6	72	72	154.57	2026-02-05
1991	572	24	24	24	35.99	2026-02-04
1992	572	5	48	48	108.81	2026-02-04
1993	572	9	24	24	127.29	2026-02-04
1994	572	27	24	24	16.9	2026-02-04
1995	572	20	18	18	67.24	2026-02-04
1996	573	26	6	6	52.75	2026-02-05
1997	573	23	24	12	44.56	2026-02-05
1998	573	24	24	24	34.88	2026-02-05
1999	573	12	24	24	138.3	2026-02-05
2000	574	6	72	72	154.57	2026-02-04
2001	574	15	12	12	170.21	2026-02-04
2002	574	4	12	12	37.77	2026-02-04
2003	575	2	6	6	102.24	2026-02-04
2004	575	13	12	12	95.59	2026-02-04
2005	575	37	48	48	126.98	2026-02-04
2006	576	3	12	12	26.74	2026-02-04
2007	576	31	24	24	150.44	2026-02-04
2008	576	37	24	24	129.57	2026-02-04
2009	576	17	12	12	53.01	2026-02-04
2010	577	37	48	48	129.57	2026-02-06
2011	577	15	36	36	170.21	2026-02-06
2012	577	11	6	6	195.04	2026-02-06
2013	577	27	36	36	17.24	2026-02-06
2014	577	6	48	48	154.57	2026-02-06
2015	578	26	6	6	55.53	2026-02-06
2016	578	13	36	36	97.54	2026-02-06
2017	578	40	12	12	38.67	2026-02-06
2018	578	19	24	24	153.58	2026-02-06
2019	578	16	12	12	161.56	2026-02-06
2020	579	37	24	24	126.98	2026-02-05
2021	579	15	12	12	166.81	2026-02-05
2022	579	29	6	6	46.38	2026-02-05
2023	579	26	18	18	54.42	2026-02-05
2024	580	37	72	72	129.57	2026-02-06
2025	580	24	24	24	36.72	2026-02-06
2026	580	12	48	48	145.58	2026-02-06
2027	580	2	6	6	104.33	2026-02-06
2028	580	5	48	48	111.03	2026-02-06
2029	581	19	24	24	153.58	2026-02-06
2030	581	31	72	72	150.44	2026-02-06
2031	582	4	24	24	37.01	2026-02-06
2032	582	39	12	12	31.87	2026-02-06
2033	582	6	48	48	151.48	2026-02-06
2034	582	37	72	72	126.98	2026-02-06
2035	582	9	24	24	127.29	2026-02-06
2036	583	25	6	6	167.68	2026-02-06
2037	583	1	12	12	12.24	2026-02-06
2038	583	33	18	18	114.93	2026-02-06
2039	584	23	12	0	44.56	\N
2040	584	25	18	18	162.54	2026-02-07
2041	584	37	24	24	123.09	2026-02-07
2042	584	33	18	18	111.42	2026-02-07
2043	584	16	12	12	153.48	2026-02-07
2044	585	34	12	12	128.16	2026-02-06
2045	585	2	12	12	99.11	2026-02-06
2046	586	38	36	36	152.33	2026-02-06
2047	586	12	24	24	142.67	2026-02-06
2048	587	13	36	36	97.54	2026-02-06
2049	587	12	48	48	145.58	2026-02-06
2050	587	33	6	6	117.28	2026-02-06
2051	588	25	12	12	171.1	2026-02-06
2052	588	24	72	72	36.72	2026-02-06
2053	588	12	72	72	145.58	2026-02-06
2054	589	13	24	24	92.66	2026-02-06
2055	589	16	24	24	153.48	2026-02-06
2056	590	30	48	48	184.29	2026-02-06
2057	590	16	24	24	161.56	2026-02-06
2058	590	11	6	6	195.04	2026-02-06
2059	590	40	18	18	38.67	2026-02-06
2060	591	1	12	12	12.49	2026-02-07
2061	591	13	36	36	97.54	2026-02-07
2062	591	17	12	12	53.01	2026-02-07
2063	592	14	12	12	110.38	2026-02-06
2064	592	19	72	72	145.9	2026-02-06
2065	593	2	12	12	99.11	2026-02-07
2066	593	23	24	0	44.56	\N
2067	593	38	36	36	147.67	2026-02-07
2068	593	28	24	24	167.43	2026-02-07
2069	594	32	18	18	124.18	2026-02-07
2070	594	12	48	48	145.58	2026-02-07
2071	594	23	12	12	46.91	2026-02-07
2072	594	35	12	12	125.1	2026-02-07
2073	594	31	24	24	150.44	2026-02-07
2074	595	38	36	36	155.44	2026-02-08
2075	595	14	24	24	116.19	2026-02-08
2076	595	29	18	18	47.33	2026-02-08
2077	595	31	72	72	150.44	2026-02-08
2078	596	33	12	12	114.93	2026-02-08
2079	596	26	12	12	54.42	2026-02-08
2080	596	5	72	72	108.81	2026-02-08
2081	596	12	48	48	142.67	2026-02-08
2082	596	37	24	24	126.98	2026-02-08
2083	597	15	36	36	161.7	2026-02-09
2084	597	36	72	72	113.56	2026-02-09
2085	597	17	6	6	50.36	2026-02-09
2086	597	28	36	36	167.43	2026-02-09
2087	598	27	24	24	17.24	2026-02-08
2088	598	16	24	24	161.56	2026-02-08
2089	598	31	24	24	150.44	2026-02-08
2090	598	5	72	72	111.03	2026-02-08
2091	599	38	24	24	155.44	2026-02-08
2092	599	20	12	12	68.61	2026-02-08
2093	600	24	48	48	36.72	2026-02-08
2094	600	27	12	12	17.24	2026-02-08
2095	600	30	48	48	184.29	2026-02-08
2096	601	31	48	48	150.44	2026-02-08
2097	601	9	48	48	129.89	2026-02-08
2098	601	30	48	48	184.29	2026-02-08
2099	601	26	12	12	55.53	2026-02-08
2100	601	2	6	6	104.33	2026-02-08
2101	602	29	18	18	47.33	2026-02-09
2102	602	37	24	24	129.57	2026-02-09
2103	603	17	6	6	53.01	2026-02-10
2104	603	9	72	72	129.89	2026-02-10
2105	603	31	24	24	150.44	2026-02-10
2106	603	29	18	18	47.33	2026-02-10
2107	604	18	72	72	78.69	2026-02-09
2108	604	16	12	12	153.48	2026-02-09
2109	605	15	36	36	170.21	2026-02-09
2110	605	33	12	12	117.28	2026-02-09
2111	605	20	18	18	68.61	2026-02-09
2112	606	5	24	24	108.81	2026-02-09
2113	606	27	36	36	16.9	2026-02-09
2114	607	21	24	24	59.84	2026-02-09
2115	607	1	18	18	12.49	2026-02-09
2116	607	2	12	12	104.33	2026-02-09
2117	607	37	48	48	129.57	2026-02-09
2118	607	26	12	12	55.53	2026-02-09
2119	608	37	24	24	129.57	2026-02-09
2120	608	22	12	12	165.43	2026-02-09
2121	609	24	72	72	34.88	2026-02-09
2122	609	39	18	18	30.89	2026-02-09
2123	609	10	24	24	71.16	2026-02-09
2124	609	21	72	58	56.85	2026-02-09
2125	610	7	18	18	151.96	2026-02-10
2126	610	19	72	72	145.9	2026-02-10
2127	611	20	12	12	68.61	2026-02-09
2128	611	27	12	12	17.24	2026-02-09
2129	612	16	36	36	161.56	2026-02-09
2130	612	38	12	12	155.44	2026-02-09
2131	612	21	24	0	59.84	\N
2132	612	18	48	48	82.83	2026-02-09
2133	612	11	18	18	195.04	2026-02-09
2134	613	2	18	18	104.33	2026-02-09
2135	613	3	12	12	26.74	2026-02-09
2136	613	4	12	12	37.77	2026-02-09
2137	614	5	72	72	108.81	2026-02-10
2138	614	4	24	24	37.01	2026-02-10
2139	615	20	6	6	67.24	2026-02-10
2140	615	8	18	18	48.81	2026-02-10
2141	615	33	6	6	114.93	2026-02-10
2142	616	31	72	72	147.43	2026-02-11
2143	616	37	24	24	126.98	2026-02-11
2144	617	11	18	18	195.04	2026-02-11
2145	617	20	18	18	68.61	2026-02-11
2146	618	10	24	24	74.91	2026-02-11
2147	618	16	12	12	161.56	2026-02-11
2148	618	12	24	24	145.58	2026-02-11
2149	618	1	18	18	12.49	2026-02-11
2150	618	2	6	6	104.33	2026-02-11
2151	619	9	48	48	129.89	2026-02-11
2152	619	27	12	12	17.24	2026-02-11
2153	619	37	72	72	129.57	2026-02-11
2154	620	18	48	48	82.83	2026-02-11
2155	620	9	72	72	129.89	2026-02-11
2156	620	4	12	12	37.77	2026-02-11
2157	621	7	18	18	159.96	2026-02-11
2158	621	39	12	12	32.52	2026-02-11
2159	621	12	48	48	145.58	2026-02-11
2160	621	28	36	36	176.24	2026-02-11
2161	621	24	24	24	36.72	2026-02-11
2162	622	30	72	72	184.29	2026-02-12
2163	622	22	18	18	165.43	2026-02-12
2164	623	2	18	18	102.24	2026-02-11
2165	623	25	18	18	167.68	2026-02-11
2166	624	31	72	46	150.44	2026-02-11
2167	624	40	6	6	38.67	2026-02-11
2168	624	37	24	24	129.57	2026-02-11
2169	625	9	72	72	129.89	2026-02-11
2170	625	31	72	0	150.44	\N
2171	625	16	36	36	161.56	2026-02-11
2172	625	23	24	0	46.91	\N
2173	626	9	48	48	129.89	2026-02-11
2174	626	1	6	6	12.49	2026-02-11
2175	626	5	48	48	111.03	2026-02-11
2176	627	21	24	24	58.64	2026-02-12
2177	627	13	24	24	95.59	2026-02-12
2178	627	25	18	18	167.68	2026-02-12
2179	628	37	48	48	123.09	2026-02-12
2180	628	6	72	72	146.84	2026-02-12
2181	628	24	48	48	34.88	2026-02-12
2182	629	38	24	18	147.67	2026-02-12
2183	629	1	6	6	11.87	2026-02-12
2184	630	16	36	36	158.33	2026-02-12
2185	630	12	24	24	142.67	2026-02-12
2186	630	13	12	12	95.59	2026-02-12
2187	630	31	72	72	147.43	2026-02-12
2188	630	25	18	18	167.68	2026-02-12
2189	631	13	24	24	97.54	2026-02-12
2190	631	15	24	24	170.21	2026-02-12
2191	631	27	36	36	17.24	2026-02-12
2192	631	31	48	48	150.44	2026-02-12
2193	632	23	12	12	46.91	2026-02-12
2194	632	37	48	48	129.57	2026-02-12
2195	633	1	6	6	11.87	2026-02-13
2196	633	23	24	0	44.56	\N
2197	634	23	24	0	46.91	\N
2198	634	18	48	48	82.83	2026-02-13
2199	635	3	12	12	25.4	2026-02-12
2200	635	13	24	15	92.66	2026-02-12
2201	635	29	6	6	44.96	2026-02-12
2202	636	23	36	36	46.91	2026-02-12
2203	636	13	12	0	97.54	\N
2204	636	37	72	72	129.57	2026-02-12
2205	637	26	18	18	55.53	2026-02-12
2206	637	11	6	6	195.04	2026-02-12
2207	637	23	12	12	46.91	2026-02-12
2208	637	40	12	12	38.67	2026-02-12
2209	637	14	36	36	116.19	2026-02-12
2210	638	29	6	6	46.38	2026-02-14
2211	638	24	72	72	35.99	2026-02-14
2212	639	29	12	0	47.33	\N
2213	639	25	12	12	171.1	2026-02-14
2214	639	1	18	18	12.49	2026-02-14
2215	640	38	12	12	155.44	2026-02-13
2216	640	16	24	24	161.56	2026-02-13
2217	640	35	12	12	125.1	2026-02-13
2218	640	37	72	72	129.57	2026-02-13
2219	641	12	72	72	145.58	2026-02-13
2220	641	30	72	72	184.29	2026-02-13
2221	641	21	48	48	59.84	2026-02-13
2222	641	2	18	18	104.33	2026-02-13
2223	641	15	36	36	170.21	2026-02-13
2224	642	30	72	72	180.6	2026-02-13
2225	642	29	6	6	46.38	2026-02-13
2226	642	11	18	18	191.14	2026-02-13
2227	642	13	24	24	95.59	2026-02-13
2228	643	36	24	24	117.15	2026-02-13
2229	643	16	12	12	158.33	2026-02-13
2230	643	25	6	6	167.68	2026-02-13
2231	643	26	12	12	54.42	2026-02-13
2232	643	5	72	72	108.81	2026-02-13
2233	644	2	12	12	99.11	2026-02-13
2234	644	37	24	24	123.09	2026-02-13
2235	644	33	18	18	111.42	2026-02-13
2236	644	8	18	18	47.32	2026-02-13
2237	645	19	24	24	153.58	2026-02-13
2238	645	6	48	48	154.57	2026-02-13
2239	645	3	36	36	26.74	2026-02-13
2240	645	34	12	12	134.91	2026-02-13
2241	646	38	24	24	155.44	2026-02-15
2242	646	29	18	0	47.33	\N
2243	646	3	24	24	26.74	2026-02-15
2244	646	7	6	6	159.96	2026-02-15
2245	646	4	36	36	37.77	2026-02-15
2246	647	6	24	24	154.57	2026-02-15
2247	647	14	12	12	116.19	2026-02-15
2248	647	22	6	6	165.43	2026-02-15
2249	648	16	36	36	161.56	2026-02-16
2250	648	40	6	6	38.67	2026-02-16
2251	649	6	72	72	154.57	2026-02-16
2252	649	12	24	24	145.58	2026-02-16
2253	649	15	36	36	170.21	2026-02-16
2254	649	24	72	72	36.72	2026-02-16
2255	650	23	36	36	46.91	2026-02-17
2256	650	14	36	36	116.19	2026-02-17
2257	650	2	6	6	104.33	2026-02-17
2258	650	6	72	72	154.57	2026-02-17
2259	651	13	12	12	97.54	2026-02-16
2260	651	12	24	24	145.58	2026-02-16
2261	651	15	36	36	170.21	2026-02-16
2262	651	16	36	36	161.56	2026-02-16
2263	652	37	24	24	126.98	2026-02-17
2264	652	35	36	36	122.6	2026-02-17
2265	652	26	6	6	54.42	2026-02-17
2266	652	38	12	12	152.33	2026-02-17
2267	653	33	18	18	117.28	2026-02-17
2268	653	23	36	0	46.91	\N
2269	654	5	72	72	105.48	2026-02-16
2270	654	18	24	24	78.69	2026-02-16
2271	655	30	48	48	184.29	2026-02-16
2272	655	37	72	72	129.57	2026-02-16
2273	656	23	36	24	46.91	2026-02-17
2274	656	28	36	36	176.24	2026-02-17
2275	656	38	36	36	155.44	2026-02-17
2276	656	6	24	24	154.57	2026-02-17
2277	656	30	72	72	184.29	2026-02-17
2278	657	12	24	24	138.3	2026-02-16
2279	657	24	48	48	34.88	2026-02-16
2280	657	31	72	72	142.92	2026-02-16
2281	657	34	36	36	128.16	2026-02-16
2282	657	37	24	24	123.09	2026-02-16
2283	658	37	48	48	123.09	2026-02-16
2284	658	4	12	12	35.88	2026-02-16
2285	658	33	18	18	111.42	2026-02-16
2286	658	36	24	24	113.56	2026-02-16
2287	659	9	48	48	129.89	2026-02-16
2288	659	26	18	18	55.53	2026-02-16
2289	659	37	24	24	129.57	2026-02-16
2290	659	12	72	72	145.58	2026-02-16
2291	660	39	6	6	32.52	2026-02-17
2292	660	6	72	72	154.57	2026-02-17
2293	660	4	36	36	37.77	2026-02-17
2294	661	39	18	18	32.52	2026-02-17
2295	661	3	12	12	26.74	2026-02-17
2296	661	40	18	18	38.67	2026-02-17
2297	661	8	18	18	49.81	2026-02-17
2298	662	17	18	18	51.95	2026-02-18
2299	662	26	18	18	54.42	2026-02-18
2300	662	20	6	6	67.24	2026-02-18
2301	662	12	24	24	142.67	2026-02-18
2302	662	11	18	18	191.14	2026-02-18
2303	663	20	12	12	68.61	2026-02-17
2304	663	38	24	24	155.44	2026-02-17
2305	663	31	48	48	150.44	2026-02-17
2306	664	1	18	17	11.87	2026-02-18
2307	664	2	12	12	99.11	2026-02-18
2308	665	16	12	12	161.56	2026-02-19
2309	665	38	12	12	155.44	2026-02-19
2310	665	30	48	48	184.29	2026-02-19
2311	665	35	12	12	125.1	2026-02-19
2312	665	18	24	24	82.83	2026-02-19
2313	666	2	12	12	104.33	2026-02-19
2314	666	33	18	18	117.28	2026-02-19
2315	667	31	48	48	150.44	2026-02-18
2316	667	22	12	12	165.43	2026-02-18
2317	667	6	72	72	154.57	2026-02-18
2318	667	24	48	48	36.72	2026-02-18
2319	667	35	12	12	125.1	2026-02-18
2320	668	37	48	48	129.57	2026-02-18
2321	668	27	12	12	17.24	2026-02-18
2322	668	12	24	24	145.58	2026-02-18
2323	669	19	48	48	153.58	2026-02-18
2324	669	3	24	24	26.74	2026-02-18
2325	669	37	48	48	129.57	2026-02-18
2326	669	16	36	36	161.56	2026-02-18
2327	670	3	12	12	26.74	2026-02-19
2328	670	12	48	48	145.58	2026-02-19
2329	670	6	24	24	154.57	2026-02-19
2330	671	9	24	24	123.4	2026-02-19
2331	671	33	12	12	111.42	2026-02-19
2332	671	3	24	24	25.4	2026-02-19
2333	671	4	24	24	35.88	2026-02-19
2334	671	25	6	6	162.54	2026-02-19
2335	672	1	18	18	12.49	2026-02-19
2336	672	15	36	36	170.21	2026-02-19
2337	673	19	48	24	145.9	2026-02-19
2338	673	23	24	0	44.56	\N
2339	673	6	48	48	146.84	2026-02-19
2340	673	16	36	36	153.48	2026-02-19
2341	674	31	48	48	142.92	2026-02-19
2342	674	40	6	6	36.74	2026-02-19
2343	675	33	6	6	114.93	2026-02-20
2344	675	7	6	6	156.76	2026-02-20
2345	675	20	12	12	67.24	2026-02-20
2346	675	37	72	72	126.98	2026-02-20
2347	676	22	6	6	165.43	2026-02-20
2348	676	29	12	12	47.33	2026-02-20
2349	677	23	24	0	46.91	\N
2350	677	16	36	36	161.56	2026-02-19
2351	677	39	12	12	32.52	2026-02-19
2352	677	17	18	18	53.01	2026-02-19
2353	677	32	18	18	124.18	2026-02-19
2354	678	31	24	24	150.44	2026-02-19
2355	678	37	24	24	129.57	2026-02-19
2356	679	8	12	12	49.81	2026-02-19
2357	679	22	6	6	165.43	2026-02-19
2358	680	31	24	24	142.92	2026-02-19
2359	680	5	72	24	105.48	2026-02-19
2360	680	19	48	48	145.9	2026-02-19
2361	680	9	72	72	123.4	2026-02-19
2362	680	24	72	72	34.88	2026-02-19
2363	681	36	48	48	119.54	2026-02-19
2364	681	31	24	24	150.44	2026-02-19
2365	681	35	12	12	125.1	2026-02-19
2366	682	16	12	12	161.56	2026-02-19
2367	682	31	48	48	150.44	2026-02-19
2368	682	12	48	48	145.58	2026-02-19
2369	683	38	12	12	147.67	2026-02-19
2370	683	9	48	48	123.4	2026-02-19
2371	683	6	48	48	146.84	2026-02-19
2372	683	2	18	18	99.11	2026-02-19
2373	683	29	18	18	44.96	2026-02-19
2374	684	39	12	12	32.52	2026-02-20
2375	684	32	6	6	124.18	2026-02-20
2376	684	16	36	36	161.56	2026-02-20
2377	684	37	48	48	129.57	2026-02-20
2378	685	6	24	24	151.48	2026-02-20
2379	685	30	48	48	180.6	2026-02-20
2380	685	33	12	1	114.93	2026-02-20
2381	685	26	18	18	54.42	2026-02-20
2382	685	3	24	24	26.21	2026-02-20
2383	686	16	36	36	161.56	2026-02-20
2384	686	15	24	24	170.21	2026-02-20
2385	686	1	12	12	12.49	2026-02-20
2386	687	15	12	12	170.21	2026-02-20
2387	687	40	12	12	38.67	2026-02-20
2388	687	34	12	12	134.91	2026-02-20
2389	688	31	72	72	150.44	2026-02-22
2390	688	35	24	24	125.1	2026-02-22
2391	688	6	48	48	154.57	2026-02-22
2392	688	22	6	6	165.43	2026-02-22
2393	689	23	36	36	46.91	2026-02-23
2394	689	11	12	12	195.04	2026-02-23
2395	689	26	18	18	55.53	2026-02-23
2396	689	16	12	12	161.56	2026-02-23
2397	689	31	24	24	150.44	2026-02-23
2398	690	2	6	6	102.24	2026-02-23
2399	690	24	24	24	35.99	2026-02-23
2400	691	26	18	18	54.42	2026-02-23
2401	691	31	72	72	147.43	2026-02-23
2402	691	7	12	12	156.76	2026-02-23
2403	692	1	12	12	11.87	2026-02-23
2404	692	24	48	48	34.88	2026-02-23
2405	693	23	24	0	46.91	\N
2406	693	31	72	72	150.44	2026-02-24
2407	694	38	24	24	155.44	2026-02-23
2408	694	17	12	12	53.01	2026-02-23
2409	695	15	24	24	170.21	2026-02-23
2410	695	6	72	40	154.57	2026-02-23
2411	695	39	6	6	32.52	2026-02-23
2412	695	12	48	48	145.58	2026-02-23
2413	696	16	12	12	161.56	2026-02-24
2414	696	35	36	36	125.1	2026-02-24
2415	697	8	12	12	49.81	2026-02-24
2416	697	21	72	72	59.84	2026-02-24
2417	698	8	6	6	48.81	2026-02-24
2418	698	26	12	12	54.42	2026-02-24
2419	698	39	18	18	31.87	2026-02-24
2420	699	31	48	48	142.92	2026-02-24
2421	699	27	36	32	16.38	2026-02-24
2422	700	31	72	72	150.44	2026-02-24
2423	700	4	12	12	37.77	2026-02-24
2424	700	37	48	48	129.57	2026-02-24
2425	700	2	12	12	104.33	2026-02-24
2426	701	33	6	6	117.28	2026-02-24
2427	701	37	24	24	129.57	2026-02-24
2428	702	37	24	24	129.57	2026-02-25
2429	702	12	72	72	145.58	2026-02-25
2430	703	29	6	6	47.33	2026-02-26
2431	703	31	24	24	150.44	2026-02-26
2432	703	5	48	48	111.03	2026-02-26
2433	703	25	12	12	171.1	2026-02-26
2434	703	13	36	36	97.54	2026-02-26
2435	704	8	6	6	49.81	2026-02-25
2436	704	37	24	24	129.57	2026-02-25
2437	704	31	24	24	150.44	2026-02-25
2438	704	27	12	12	17.24	2026-02-25
2439	705	19	48	48	153.58	2026-02-25
2440	705	16	24	24	161.56	2026-02-25
2441	706	26	6	6	55.53	2026-02-25
2442	706	6	72	72	154.57	2026-02-25
2443	706	37	48	48	129.57	2026-02-25
2444	706	3	36	36	26.74	2026-02-25
2445	707	16	12	12	158.33	2026-02-26
2446	707	37	24	24	126.98	2026-02-26
2447	707	2	6	6	102.24	2026-02-26
2448	708	8	6	6	47.32	2026-02-25
2449	708	13	12	12	92.66	2026-02-25
2450	708	6	48	48	146.84	2026-02-25
2451	708	14	36	36	110.38	2026-02-25
2452	709	38	36	36	155.44	2026-02-26
2453	709	18	48	48	82.83	2026-02-26
2454	709	32	18	18	124.18	2026-02-26
2455	709	26	6	6	55.53	2026-02-26
2456	710	22	6	6	157.16	2026-02-26
2457	710	9	72	72	123.4	2026-02-26
2458	710	17	18	18	50.36	2026-02-26
2459	710	2	18	18	99.11	2026-02-26
2460	710	6	72	72	146.84	2026-02-26
2461	711	16	24	24	158.33	2026-02-26
2462	711	6	48	48	151.48	2026-02-26
2463	712	26	12	12	52.75	2026-02-26
2464	712	11	6	6	185.29	2026-02-26
2465	712	22	6	6	157.16	2026-02-26
2466	712	3	24	24	25.4	2026-02-26
2467	713	7	12	12	159.96	2026-02-26
2468	713	3	24	24	26.74	2026-02-26
2469	714	35	36	36	122.6	2026-02-27
2470	714	6	24	24	151.48	2026-02-27
2471	714	23	24	24	45.97	2026-02-27
2472	714	7	12	12	156.76	2026-02-27
2473	714	19	24	24	150.51	2026-02-27
2474	715	12	48	48	145.58	2026-02-26
2475	715	25	18	0	171.1	\N
2476	715	14	12	12	116.19	2026-02-26
2477	715	27	36	0	17.24	\N
2478	716	31	72	72	150.44	2026-02-26
2479	716	13	24	24	97.54	2026-02-26
2480	717	38	12	12	152.33	2026-02-26
2481	717	33	18	18	114.93	2026-02-26
2482	717	20	6	6	67.24	2026-02-26
2483	717	16	36	36	158.33	2026-02-26
2484	717	15	12	12	166.81	2026-02-26
2485	718	31	24	24	150.44	2026-02-27
2486	718	26	12	12	55.53	2026-02-27
2487	718	30	72	72	184.29	2026-02-27
2488	719	12	72	72	142.67	2026-02-28
2489	719	40	18	18	37.9	2026-02-28
2490	719	13	24	24	95.59	2026-02-28
2491	720	19	24	24	145.9	2026-02-28
2492	720	16	12	12	153.48	2026-02-28
2493	720	29	6	6	44.96	2026-02-28
2494	721	13	36	36	97.54	2026-02-28
2495	721	15	12	12	170.21	2026-02-28
2496	721	35	24	24	125.1	2026-02-28
2497	721	37	24	24	129.57	2026-02-28
2498	721	31	72	72	150.44	2026-02-28
2499	722	20	12	12	65.18	2026-02-27
2500	722	8	6	6	47.32	2026-02-27
2501	723	6	72	0	154.57	\N
2502	723	1	6	6	12.49	2026-02-27
2503	724	27	12	12	17.24	2026-02-28
2504	724	16	12	12	161.56	2026-02-28
2505	724	32	12	12	124.18	2026-02-28
2506	724	29	6	6	47.33	2026-02-28
2507	725	4	12	12	37.77	2026-02-28
2508	725	37	48	48	129.57	2026-02-28
2509	725	24	24	24	36.72	2026-02-28
2510	725	31	24	24	150.44	2026-02-28
2511	726	40	12	12	36.74	2026-03-02
2512	726	8	6	6	47.32	2026-03-02
2513	726	33	12	12	111.42	2026-03-02
2514	726	27	24	24	16.38	2026-03-02
2515	726	5	72	72	105.48	2026-03-02
2516	727	12	48	48	142.67	2026-03-02
2517	727	5	24	24	108.81	2026-03-02
2518	727	38	12	12	152.33	2026-03-02
2519	727	23	24	24	45.97	2026-03-02
2520	728	15	36	36	170.21	2026-03-03
2521	728	16	36	36	161.56	2026-03-03
2522	728	13	24	24	97.54	2026-03-03
2523	728	19	48	48	153.58	2026-03-03
2524	729	16	12	12	153.48	2026-03-03
2525	729	21	24	24	56.85	2026-03-03
2526	729	35	36	36	118.84	2026-03-03
2527	729	12	48	48	138.3	2026-03-03
2528	730	12	24	24	145.58	2026-03-03
2529	730	39	6	6	32.52	2026-03-03
2530	730	6	72	72	154.57	2026-03-03
2531	730	22	6	6	165.43	2026-03-03
2532	730	37	24	24	129.57	2026-03-03
2533	731	29	12	12	47.33	2026-03-02
2534	731	21	72	72	59.84	2026-03-02
2535	731	2	6	6	104.33	2026-03-02
2536	731	4	36	36	37.77	2026-03-02
2537	732	33	6	6	111.42	2026-03-03
2538	732	19	24	24	145.9	2026-03-03
2539	732	8	18	18	47.32	2026-03-03
2540	732	23	12	12	44.56	2026-03-03
2541	732	38	24	24	147.67	2026-03-03
2542	733	26	18	18	55.53	2026-03-03
2543	733	38	24	24	155.44	2026-03-03
2544	733	12	24	24	145.58	2026-03-03
2545	733	37	72	72	129.57	2026-03-03
2546	734	24	72	72	36.72	2026-03-03
2547	734	31	72	72	150.44	2026-03-03
2548	734	16	12	12	161.56	2026-03-03
2549	734	39	6	6	32.52	2026-03-03
2550	735	33	12	12	117.28	2026-03-04
2551	735	12	48	48	145.58	2026-03-04
2552	735	20	18	18	68.61	2026-03-04
2553	735	31	72	72	150.44	2026-03-04
2554	736	15	24	24	170.21	2026-03-03
2555	736	31	24	24	150.44	2026-03-03
2556	737	18	72	72	81.17	2026-03-04
2557	737	23	12	12	45.97	2026-03-04
2558	737	5	72	72	108.81	2026-03-04
2559	738	1	12	12	12.24	2026-03-03
2560	738	31	48	48	147.43	2026-03-03
2561	738	20	6	6	67.24	2026-03-03
2562	739	5	72	72	108.81	2026-03-04
2563	739	35	12	12	122.6	2026-03-04
2564	739	39	6	6	31.87	2026-03-04
2565	739	8	18	18	48.81	2026-03-04
2566	740	5	24	24	105.48	2026-03-04
2567	740	22	6	6	157.16	2026-03-04
2568	740	19	24	24	145.9	2026-03-04
2569	740	12	72	72	138.3	2026-03-04
2570	740	35	36	13	118.84	2026-03-04
2571	741	37	48	48	129.57	2026-03-04
2572	741	39	12	12	32.52	2026-03-04
2573	741	24	24	24	36.72	2026-03-04
2574	741	23	24	0	46.91	\N
2575	742	34	12	12	134.91	2026-03-05
2576	742	36	72	72	119.54	2026-03-05
2577	742	33	12	12	117.28	2026-03-05
2578	743	12	48	48	145.58	2026-03-05
2579	743	40	12	12	38.67	2026-03-05
2580	743	20	18	18	68.61	2026-03-05
2581	743	4	24	24	37.77	2026-03-05
2582	744	22	6	6	157.16	2026-03-05
2583	744	13	12	12	92.66	2026-03-05
2584	744	39	12	12	30.89	2026-03-05
2585	744	12	72	72	138.3	2026-03-05
2586	744	15	36	36	161.7	2026-03-05
2587	745	27	24	24	17.24	2026-03-04
2588	745	37	48	48	129.57	2026-03-04
2589	745	31	24	24	150.44	2026-03-04
2590	746	19	72	72	153.58	2026-03-04
2591	746	24	48	48	36.72	2026-03-04
2592	746	39	6	6	32.52	2026-03-04
2593	747	4	12	12	37.01	2026-03-04
2594	747	32	12	12	121.7	2026-03-04
2595	748	1	18	18	12.24	2026-03-04
2596	748	39	12	12	31.87	2026-03-04
2597	748	19	24	24	150.51	2026-03-04
2598	748	12	48	48	142.67	2026-03-04
2599	748	20	18	18	67.24	2026-03-04
2600	749	24	48	48	36.72	2026-03-05
2601	749	15	12	12	170.21	2026-03-05
2602	749	20	6	6	68.61	2026-03-05
2603	750	24	72	72	36.72	2026-03-05
2604	750	15	24	24	170.21	2026-03-05
2605	750	40	18	18	38.67	2026-03-05
2606	751	9	48	48	127.29	2026-03-06
2607	751	31	72	72	147.43	2026-03-06
2608	751	2	12	12	102.24	2026-03-06
2609	751	5	48	48	108.81	2026-03-06
2610	751	12	48	48	142.67	2026-03-06
2611	752	13	36	27	95.59	2026-03-05
2612	752	6	72	72	151.48	2026-03-05
2613	753	35	36	36	122.6	2026-03-05
2614	753	26	18	18	54.42	2026-03-05
2615	753	31	72	72	147.43	2026-03-05
2616	753	37	72	72	126.98	2026-03-05
2617	754	39	6	6	30.89	2026-03-05
2618	754	1	6	6	11.87	2026-03-05
2619	754	17	6	6	50.36	2026-03-05
2620	755	16	36	36	161.56	2026-03-06
2621	755	9	24	24	129.89	2026-03-06
2622	755	12	24	24	145.58	2026-03-06
2623	755	13	36	36	97.54	2026-03-06
2624	756	24	72	72	36.72	2026-03-06
2625	756	6	72	72	154.57	2026-03-06
2626	757	39	6	6	32.52	2026-03-06
2627	757	27	24	24	17.24	2026-03-06
2628	757	37	72	72	129.57	2026-03-06
2629	757	16	12	12	161.56	2026-03-06
2630	757	2	18	18	104.33	2026-03-06
2631	758	13	24	0	92.66	\N
2632	758	21	24	24	56.85	2026-03-07
2633	759	23	12	12	46.91	2026-03-07
2634	759	7	6	6	159.96	2026-03-07
2635	759	19	72	72	153.58	2026-03-07
2636	759	39	6	6	32.52	2026-03-07
2637	759	31	24	24	150.44	2026-03-07
2638	760	27	12	12	17.24	2026-03-07
2639	760	4	24	24	37.77	2026-03-07
2640	760	33	6	6	117.28	2026-03-07
2641	760	13	36	36	97.54	2026-03-07
2642	760	40	18	18	38.67	2026-03-07
2643	761	23	24	24	45.97	2026-03-06
2644	761	13	36	36	95.59	2026-03-06
2645	762	19	72	72	153.58	2026-03-06
2646	762	31	24	24	150.44	2026-03-06
2647	763	4	12	12	37.77	2026-03-06
2648	763	3	24	24	26.74	2026-03-06
2649	763	25	12	12	171.1	2026-03-06
2650	763	38	36	36	155.44	2026-03-06
2651	763	9	24	24	129.89	2026-03-06
2652	764	37	24	24	129.57	2026-03-06
2653	764	39	12	12	32.52	2026-03-06
2654	764	25	18	18	171.1	2026-03-06
2655	765	22	18	18	162.12	2026-03-06
2656	765	2	6	6	102.24	2026-03-06
2657	765	17	12	12	51.95	2026-03-06
2658	765	3	24	24	26.21	2026-03-06
2659	766	19	24	24	145.9	2026-03-07
2660	766	38	12	12	147.67	2026-03-07
2661	766	28	24	24	167.43	2026-03-07
2662	767	6	48	48	146.84	2026-03-06
2663	767	1	12	8	11.87	2026-03-06
2664	767	30	72	72	175.08	2026-03-06
2665	768	8	6	6	48.81	2026-03-08
2666	768	5	24	24	108.81	2026-03-08
2667	768	29	6	6	46.38	2026-03-08
2668	768	19	72	72	150.51	2026-03-08
2669	768	38	36	36	152.33	2026-03-08
2670	769	30	24	24	184.29	2026-03-07
2671	769	26	6	6	55.53	2026-03-07
2672	769	31	48	48	150.44	2026-03-07
2673	769	29	18	18	47.33	2026-03-07
2674	769	2	18	18	104.33	2026-03-07
2675	770	37	72	72	123.09	2026-03-07
2676	770	8	18	18	47.32	2026-03-07
2677	771	7	12	12	159.96	2026-03-07
2678	771	26	12	12	55.53	2026-03-07
2679	772	31	72	72	150.44	2026-03-07
2680	772	6	24	24	154.57	2026-03-07
2681	772	37	72	72	129.57	2026-03-07
2682	773	1	12	12	12.49	2026-03-09
2683	773	6	24	24	154.57	2026-03-09
2684	773	15	24	24	170.21	2026-03-09
2685	773	24	48	48	36.72	2026-03-09
2686	773	34	36	36	134.91	2026-03-09
2687	774	31	72	72	150.44	2026-03-09
2688	774	12	24	24	145.58	2026-03-09
2689	775	37	48	48	129.57	2026-03-08
2690	775	28	24	24	176.24	2026-03-08
2691	775	33	18	18	117.28	2026-03-08
2692	775	16	24	24	161.56	2026-03-08
2693	776	19	48	24	153.58	2026-03-08
2694	776	18	72	72	82.83	2026-03-08
2695	776	6	24	24	154.57	2026-03-08
2696	776	8	18	18	49.81	2026-03-08
2697	776	20	18	18	68.61	2026-03-08
2698	777	14	24	24	110.38	2026-03-09
2699	777	36	24	24	113.56	2026-03-09
2700	777	27	24	24	16.38	2026-03-09
2701	777	26	18	18	52.75	2026-03-09
2702	777	2	18	18	99.11	2026-03-09
2703	778	14	36	36	113.87	2026-03-09
2704	778	4	36	36	37.01	2026-03-09
2705	778	33	6	6	114.93	2026-03-09
2706	778	35	36	36	122.6	2026-03-09
2707	778	2	12	12	102.24	2026-03-09
2708	779	11	6	6	195.04	2026-03-09
2709	779	3	12	12	26.74	2026-03-09
2710	779	16	36	36	161.56	2026-03-09
2711	779	39	6	6	32.52	2026-03-09
2712	779	7	12	12	159.96	2026-03-09
2713	780	4	12	12	37.77	2026-03-10
2714	780	8	12	12	49.81	2026-03-10
2715	780	12	24	24	145.58	2026-03-10
2716	780	31	48	48	150.44	2026-03-10
2717	781	27	12	12	17.24	2026-03-09
2718	781	2	12	12	104.33	2026-03-09
2719	781	31	48	48	150.44	2026-03-09
2720	782	12	48	48	145.58	2026-03-09
2721	782	13	24	0	97.54	\N
2722	783	3	24	24	26.74	2026-03-09
2723	783	29	12	12	47.33	2026-03-09
2724	784	4	36	36	37.01	2026-03-09
2725	784	38	24	24	152.33	2026-03-09
2726	784	25	6	6	167.68	2026-03-09
2727	784	37	24	24	126.98	2026-03-09
2728	784	12	24	24	142.67	2026-03-09
2729	785	31	72	72	147.43	2026-03-09
2730	785	1	12	0	12.24	\N
2731	786	16	24	24	158.33	2026-03-09
2732	786	31	48	48	147.43	2026-03-09
2733	786	6	24	24	151.48	2026-03-09
2734	786	11	12	12	191.14	2026-03-09
2735	787	32	18	18	124.18	2026-03-09
2736	787	12	72	72	145.58	2026-03-09
2737	787	31	72	72	150.44	2026-03-09
2738	787	16	36	36	161.56	2026-03-09
2739	787	18	24	24	82.83	2026-03-09
2740	788	39	18	18	32.52	2026-03-09
2741	788	24	72	72	36.72	2026-03-09
2742	789	4	24	24	37.77	2026-03-11
2743	789	33	12	12	117.28	2026-03-11
2744	789	14	36	36	116.19	2026-03-11
2745	789	31	24	24	150.44	2026-03-11
2746	789	24	24	24	36.72	2026-03-11
2747	790	4	36	36	35.88	2026-03-10
2748	790	22	12	12	157.16	2026-03-10
2749	791	25	6	6	171.1	2026-03-10
2750	791	5	24	24	111.03	2026-03-10
2751	791	26	18	18	55.53	2026-03-10
2752	791	39	6	6	32.52	2026-03-10
2753	791	9	48	48	129.89	2026-03-10
2754	792	1	18	18	11.87	2026-03-10
2755	792	6	24	24	146.84	2026-03-10
2756	792	31	24	24	142.92	2026-03-10
2757	792	10	24	24	71.16	2026-03-10
2758	792	5	24	24	105.48	2026-03-10
2759	793	13	24	24	97.54	2026-03-10
2760	793	16	36	36	161.56	2026-03-10
2761	793	31	24	24	150.44	2026-03-10
2762	793	37	72	72	129.57	2026-03-10
2763	793	1	6	0	12.49	\N
2764	794	1	6	0	11.87	\N
2765	794	3	12	12	25.4	2026-03-11
2766	795	5	48	48	111.03	2026-03-11
2767	795	8	18	18	49.81	2026-03-11
2768	795	12	48	48	145.58	2026-03-11
2769	795	19	24	24	153.58	2026-03-11
2770	796	13	24	0	92.66	\N
2771	796	30	24	24	175.08	2026-03-12
2772	796	29	12	12	44.96	2026-03-12
2773	796	26	6	6	52.75	2026-03-12
2774	796	33	18	18	111.42	2026-03-12
2775	797	16	24	24	161.56	2026-03-11
2776	797	6	24	24	154.57	2026-03-11
2777	797	26	6	6	55.53	2026-03-11
2778	797	8	18	18	49.81	2026-03-11
2779	798	28	24	24	176.24	2026-03-11
2780	798	31	24	24	150.44	2026-03-11
2781	799	25	12	12	171.1	2026-03-12
2782	799	31	24	24	150.44	2026-03-12
2783	799	39	12	12	32.52	2026-03-12
2784	799	23	12	0	46.91	\N
2785	799	37	48	48	129.57	2026-03-12
2786	800	28	24	24	167.43	2026-03-11
2787	800	17	18	18	50.36	2026-03-11
2788	800	30	72	72	175.08	2026-03-11
2789	801	26	6	6	52.75	2026-03-11
2790	801	23	12	12	44.56	2026-03-11
2791	801	29	18	18	44.96	2026-03-11
2792	802	22	12	12	157.16	2026-03-11
2793	802	16	36	36	153.48	2026-03-11
2794	802	27	12	12	16.38	2026-03-11
2795	803	7	18	18	159.96	2026-03-11
2796	803	2	18	18	104.33	2026-03-11
2797	803	18	48	48	82.83	2026-03-11
2798	803	4	24	24	37.77	2026-03-11
2799	804	5	72	48	108.81	2026-03-12
2800	804	19	72	72	150.51	2026-03-12
2801	805	2	18	18	99.11	2026-03-12
2802	805	19	24	0	145.9	\N
2803	805	15	36	36	161.7	2026-03-12
2804	805	3	12	12	25.4	2026-03-12
2805	806	15	24	24	166.81	2026-03-12
2806	806	16	36	36	158.33	2026-03-12
2807	807	4	24	24	37.77	2026-03-12
2808	807	12	24	24	145.58	2026-03-12
2809	807	36	72	72	119.54	2026-03-12
2810	808	33	12	12	114.93	2026-03-12
2811	808	20	18	18	67.24	2026-03-12
2812	809	9	48	48	129.89	2026-03-12
2813	809	39	6	6	32.52	2026-03-12
2814	809	24	24	24	36.72	2026-03-12
2815	809	16	12	12	161.56	2026-03-12
2816	809	15	24	24	170.21	2026-03-12
2817	810	25	18	12	171.1	2026-03-12
2818	810	12	48	48	145.58	2026-03-12
2819	810	15	36	36	170.21	2026-03-12
2820	811	12	72	72	138.3	2026-03-12
2821	811	3	36	36	25.4	2026-03-12
2822	811	9	72	72	123.4	2026-03-12
2823	811	11	18	18	185.29	2026-03-12
2824	811	38	12	12	147.67	2026-03-12
2825	812	12	48	48	145.58	2026-03-13
2826	812	33	6	6	117.28	2026-03-13
2827	813	1	6	6	12.49	2026-03-13
2828	813	20	6	6	68.61	2026-03-13
2829	813	8	12	10	49.81	2026-03-13
2830	813	16	36	36	161.56	2026-03-13
2831	813	6	48	48	154.57	2026-03-13
2832	814	27	36	36	16.9	2026-03-13
2833	814	2	18	18	102.24	2026-03-13
2834	814	31	24	24	147.43	2026-03-13
2835	815	17	6	6	50.36	2026-03-13
2836	815	27	12	12	16.38	2026-03-13
2837	816	12	48	48	145.58	2026-03-13
2838	816	38	36	36	155.44	2026-03-13
2839	817	31	48	48	150.44	2026-03-13
2840	817	20	6	6	68.61	2026-03-13
2841	817	8	18	18	49.81	2026-03-13
2842	817	9	24	24	129.89	2026-03-13
2843	817	37	48	48	129.57	2026-03-13
2844	818	9	72	72	123.4	2026-03-15
2845	818	40	12	12	36.74	2026-03-15
2846	818	39	12	12	30.89	2026-03-15
2847	818	31	48	48	142.92	2026-03-15
2848	818	17	12	12	50.36	2026-03-15
2849	819	18	48	48	82.83	2026-03-14
2850	819	29	6	6	47.33	2026-03-14
2851	819	26	18	18	55.53	2026-03-14
2852	819	21	48	48	59.84	2026-03-14
2853	819	13	24	24	97.54	2026-03-14
2854	820	15	36	36	170.21	2026-03-14
2855	820	4	36	36	37.77	2026-03-14
2856	820	21	72	72	59.84	2026-03-14
2857	820	38	24	24	155.44	2026-03-14
2858	820	14	24	24	116.19	2026-03-14
2859	821	19	24	24	150.51	2026-03-15
2860	821	9	72	72	127.29	2026-03-15
2861	821	6	48	48	151.48	2026-03-15
2862	821	33	18	18	114.93	2026-03-15
2863	822	13	36	36	95.59	2026-03-15
2864	822	8	12	0	48.81	\N
2865	823	25	18	18	171.1	2026-03-16
2866	823	37	72	72	129.57	2026-03-16
2867	823	38	36	36	155.44	2026-03-16
2868	823	23	12	0	46.91	\N
2869	823	31	72	72	150.44	2026-03-16
2870	824	37	24	24	126.98	2026-03-15
2871	824	6	72	72	151.48	2026-03-15
2872	825	4	36	13	37.01	2026-03-15
2873	825	6	24	24	151.48	2026-03-15
2874	825	28	36	36	172.72	2026-03-15
2875	825	35	12	12	122.6	2026-03-15
2876	825	31	72	72	147.43	2026-03-15
2877	826	19	48	48	153.58	2026-03-16
2878	826	12	24	24	145.58	2026-03-16
2879	827	33	12	12	117.28	2026-03-15
2880	827	16	24	24	161.56	2026-03-15
2881	828	30	24	24	184.29	2026-03-16
2882	828	38	24	24	155.44	2026-03-16
2883	828	33	6	6	117.28	2026-03-16
2884	829	24	48	48	36.72	2026-03-17
2885	829	38	36	36	155.44	2026-03-17
2886	829	13	36	36	97.54	2026-03-17
2887	829	36	72	72	119.54	2026-03-17
2888	829	12	48	48	145.58	2026-03-17
2889	830	6	24	24	154.57	2026-03-16
2890	830	16	12	12	161.56	2026-03-16
2891	831	12	48	48	138.3	2026-03-17
2892	831	23	12	12	44.56	2026-03-17
2893	831	16	12	12	153.48	2026-03-17
2894	832	37	72	72	126.98	2026-03-17
2895	832	40	18	18	37.9	2026-03-17
2896	832	7	6	6	156.76	2026-03-17
2897	833	39	12	12	32.52	2026-03-17
2898	833	31	24	24	150.44	2026-03-17
2899	833	26	12	12	55.53	2026-03-17
2900	833	38	24	24	155.44	2026-03-17
2901	833	15	24	24	170.21	2026-03-17
2902	834	31	72	72	150.44	2026-03-16
2903	834	24	24	24	36.72	2026-03-16
2904	834	3	36	36	26.74	2026-03-16
2905	834	28	36	36	176.24	2026-03-16
2906	834	36	48	48	119.54	2026-03-16
2907	835	30	72	72	184.29	2026-03-17
2908	835	15	12	12	170.21	2026-03-17
2909	835	39	18	18	32.52	2026-03-17
2910	835	31	24	24	150.44	2026-03-17
2911	835	9	48	48	129.89	2026-03-17
2912	836	38	24	24	155.44	2026-03-16
2913	836	33	6	6	117.28	2026-03-16
2914	836	31	24	24	150.44	2026-03-16
2915	836	35	12	12	125.1	2026-03-16
2916	837	20	18	18	65.18	2026-03-16
2917	837	10	72	72	71.16	2026-03-16
2918	837	37	72	72	123.09	2026-03-16
2919	838	23	24	24	46.91	2026-03-16
2920	838	12	72	72	145.58	2026-03-16
2921	838	18	48	48	82.83	2026-03-16
2922	839	38	12	12	155.44	2026-03-17
2923	839	9	48	48	129.89	2026-03-17
2924	839	19	48	0	153.58	\N
2925	840	29	6	6	47.33	2026-03-17
2926	840	6	72	72	154.57	2026-03-17
2927	840	12	72	72	145.58	2026-03-17
2928	840	13	36	36	97.54	2026-03-17
2929	840	38	12	12	155.44	2026-03-17
2930	841	14	36	36	116.19	2026-03-17
2931	841	22	6	6	165.43	2026-03-17
2932	841	26	18	18	55.53	2026-03-17
2933	841	9	24	24	129.89	2026-03-17
2934	841	4	12	12	37.77	2026-03-17
2935	842	25	6	0	167.68	\N
2936	842	14	36	36	113.87	2026-03-18
2937	842	16	36	36	158.33	2026-03-18
2938	843	21	48	48	58.64	2026-03-17
2939	843	12	48	48	142.67	2026-03-17
2940	843	16	24	24	158.33	2026-03-17
2941	844	3	36	36	26.21	2026-03-17
2942	844	31	24	24	147.43	2026-03-17
2943	844	18	24	24	81.17	2026-03-17
2944	844	13	36	36	95.59	2026-03-17
2945	845	2	18	18	102.24	2026-03-17
2946	845	38	12	12	152.33	2026-03-17
2947	845	7	6	6	156.76	2026-03-17
2948	845	37	72	72	126.98	2026-03-17
2949	845	40	6	6	37.9	2026-03-17
2950	846	1	18	18	12.24	2026-03-19
2951	846	6	24	24	151.48	2026-03-19
2952	846	14	36	36	113.87	2026-03-19
2953	846	16	12	12	158.33	2026-03-19
2954	846	8	12	0	48.81	\N
2955	847	33	6	6	114.93	2026-03-18
2956	847	8	6	6	48.81	2026-03-18
2957	847	31	24	24	147.43	2026-03-18
2958	847	24	48	48	35.99	2026-03-18
2959	847	15	24	24	166.81	2026-03-18
2960	848	15	12	12	161.7	2026-03-18
2961	848	20	18	18	65.18	2026-03-18
2962	849	7	18	18	159.96	2026-03-18
2963	849	17	18	18	53.01	2026-03-18
2964	849	37	24	24	129.57	2026-03-18
2965	849	23	36	36	46.91	2026-03-18
2966	849	33	12	12	117.28	2026-03-18
2967	850	4	24	24	37.01	2026-03-19
2968	850	38	12	12	152.33	2026-03-19
2969	850	35	12	12	122.6	2026-03-19
2970	850	39	18	18	31.87	2026-03-19
2971	851	23	12	12	46.91	2026-03-19
2972	851	4	36	36	37.77	2026-03-19
2973	851	31	48	48	150.44	2026-03-19
2974	851	6	72	72	154.57	2026-03-19
2975	852	30	24	24	175.08	2026-03-19
2976	852	15	12	12	161.7	2026-03-19
2977	852	20	18	18	65.18	2026-03-19
2978	852	2	6	6	99.11	2026-03-19
2979	853	27	12	12	16.9	2026-03-19
2980	853	37	24	24	126.98	2026-03-19
2981	854	8	12	9	49.81	2026-03-20
2982	854	37	72	27	129.57	2026-03-20
2983	854	13	36	36	97.54	2026-03-20
2984	855	8	18	0	47.32	\N
2985	855	30	48	48	175.08	2026-03-20
2986	855	38	24	24	147.67	2026-03-20
2987	856	12	24	24	138.3	2026-03-19
2988	856	13	12	12	92.66	2026-03-19
2989	856	21	48	48	56.85	2026-03-19
2990	856	9	48	48	123.4	2026-03-19
2991	856	40	12	12	36.74	2026-03-19
2992	857	8	18	0	48.81	\N
2993	857	30	24	24	180.6	2026-03-19
2994	857	37	72	0	126.98	\N
2995	857	33	12	12	114.93	2026-03-19
2996	858	9	48	48	129.89	2026-03-19
2997	858	24	48	48	36.72	2026-03-19
2998	858	6	24	24	154.57	2026-03-19
2999	858	15	12	12	170.21	2026-03-19
3000	859	31	48	48	150.44	2026-03-19
3001	859	18	72	72	82.83	2026-03-19
3002	859	25	6	0	171.1	\N
3003	860	24	48	48	36.72	2026-03-19
3004	860	37	72	0	129.57	\N
3005	860	39	6	6	32.52	2026-03-19
3006	860	4	36	36	37.77	2026-03-19
3007	861	24	48	48	36.72	2026-03-21
3008	861	16	36	36	161.56	2026-03-21
3009	861	31	24	24	150.44	2026-03-21
3010	861	15	36	36	170.21	2026-03-21
3011	862	39	12	12	31.87	2026-03-20
3012	862	2	18	18	102.24	2026-03-20
3013	862	37	24	24	126.98	2026-03-20
3014	862	25	6	6	167.68	2026-03-20
3015	862	15	36	13	166.81	2026-03-20
3016	863	20	18	18	68.61	2026-03-20
3017	863	39	18	18	32.52	2026-03-20
3018	863	24	24	24	36.72	2026-03-20
3019	863	2	18	18	104.33	2026-03-20
3020	863	38	12	12	155.44	2026-03-20
3021	864	13	12	12	97.54	2026-03-21
3022	864	35	12	12	125.1	2026-03-21
3023	864	25	18	18	171.1	2026-03-21
3024	864	24	48	48	36.72	2026-03-21
3025	865	29	12	12	44.96	2026-03-20
3026	865	13	36	26	92.66	2026-03-20
3027	865	31	48	48	142.92	2026-03-20
3028	866	1	18	18	11.87	2026-03-20
3029	866	27	24	24	16.38	2026-03-20
3030	866	12	24	24	138.3	2026-03-20
3031	866	5	24	24	105.48	2026-03-20
3032	867	37	72	0	123.09	\N
3033	867	31	24	24	142.92	2026-03-20
3034	867	16	12	12	153.48	2026-03-20
3035	867	3	24	24	25.4	2026-03-20
3036	868	22	18	18	157.16	2026-03-21
3037	868	15	36	36	161.7	2026-03-21
3038	868	1	18	18	11.87	2026-03-21
3039	869	8	12	0	49.81	\N
3040	869	7	18	17	159.96	2026-03-21
3041	869	5	72	72	111.03	2026-03-21
3042	869	21	24	24	59.84	2026-03-21
3043	869	33	12	12	117.28	2026-03-21
3044	870	2	6	6	99.11	2026-03-21
3045	870	29	6	6	44.96	2026-03-21
3046	870	31	72	72	142.92	2026-03-21
3047	870	33	12	12	111.42	2026-03-21
3048	870	39	12	12	30.89	2026-03-21
3049	871	21	24	24	56.85	2026-03-21
3050	871	27	12	12	16.38	2026-03-21
3051	871	3	24	24	25.4	2026-03-21
3052	871	20	6	6	65.18	2026-03-21
3053	871	14	12	12	110.38	2026-03-21
3054	872	4	12	12	37.01	2026-03-21
3055	872	6	72	72	151.48	2026-03-21
3056	872	38	12	12	152.33	2026-03-21
3057	872	10	24	24	73.41	2026-03-21
3058	873	14	12	0	116.19	\N
3059	873	37	48	48	129.57	2026-03-23
3060	873	30	48	48	184.29	2026-03-23
3061	874	31	72	72	147.43	2026-03-23
3062	874	12	48	48	142.67	2026-03-23
3063	874	26	6	6	54.42	2026-03-23
3064	874	6	72	72	151.48	2026-03-23
3065	875	25	12	12	162.54	2026-03-24
3066	875	12	48	48	138.3	2026-03-24
3067	875	16	24	24	153.48	2026-03-24
3068	876	24	48	48	36.72	2026-03-24
3069	876	13	36	36	97.54	2026-03-24
3070	876	10	24	24	74.91	2026-03-24
3071	876	1	18	18	12.49	2026-03-24
3072	877	30	72	72	175.08	2026-03-23
3073	877	5	24	24	105.48	2026-03-23
3074	877	2	12	12	99.11	2026-03-23
3075	877	12	24	24	138.3	2026-03-23
3076	877	3	12	12	25.4	2026-03-23
3077	878	12	72	72	138.3	2026-03-23
3078	878	1	12	12	11.87	2026-03-23
3079	878	18	24	24	78.69	2026-03-23
3080	879	4	24	24	37.77	2026-03-23
3081	879	31	72	72	150.44	2026-03-23
3082	879	9	72	72	129.89	2026-03-23
3083	879	16	12	12	161.56	2026-03-23
3084	879	25	12	12	171.1	2026-03-23
3085	880	1	18	18	12.24	2026-03-23
3086	880	17	12	12	51.95	2026-03-23
3087	881	9	48	48	129.89	2026-03-23
3088	881	17	6	6	53.01	2026-03-23
3089	881	21	72	72	59.84	2026-03-23
3090	881	33	12	12	117.28	2026-03-23
3091	881	26	6	6	55.53	2026-03-23
3092	882	20	18	18	67.24	2026-03-24
3093	882	40	12	12	37.9	2026-03-24
3094	883	9	48	48	123.4	2026-03-23
3095	883	38	24	24	147.67	2026-03-23
3096	883	27	36	36	16.38	2026-03-23
3097	884	2	12	12	104.33	2026-03-23
3098	884	21	72	48	59.84	2026-03-23
3099	884	33	18	18	117.28	2026-03-23
3100	885	31	48	48	142.92	2026-03-23
3101	885	37	72	72	123.09	2026-03-23
3102	885	25	12	0	162.54	\N
3103	885	16	12	12	153.48	2026-03-23
3104	886	1	12	12	12.49	2026-03-23
3105	886	24	48	48	36.72	2026-03-23
3106	887	6	24	24	154.57	2026-03-23
3107	887	11	12	12	195.04	2026-03-23
3108	887	2	18	18	104.33	2026-03-23
3109	887	22	6	6	165.43	2026-03-23
3110	887	38	12	12	155.44	2026-03-23
3111	888	25	12	12	171.1	2026-03-25
3112	888	13	12	12	97.54	2026-03-25
3113	888	18	24	24	82.83	2026-03-25
3114	888	19	48	48	153.58	2026-03-25
3115	888	26	18	18	55.53	2026-03-25
3116	889	19	72	72	145.9	2026-03-24
3117	889	6	72	72	146.84	2026-03-24
3118	890	22	6	6	165.43	2026-03-24
3119	890	37	24	24	129.57	2026-03-24
3120	890	21	24	24	59.84	2026-03-24
3121	891	18	48	48	82.83	2026-03-25
3122	891	4	36	36	37.77	2026-03-25
3123	891	31	48	48	150.44	2026-03-25
3124	891	33	6	6	117.28	2026-03-25
3125	892	32	6	6	121.7	2026-03-24
3126	892	8	6	6	48.81	2026-03-24
3127	893	21	48	0	59.84	\N
3128	893	37	48	48	129.57	2026-03-25
3129	893	3	36	36	26.74	2026-03-25
3130	893	1	18	18	12.49	2026-03-25
3131	893	18	48	48	82.83	2026-03-25
3132	894	15	12	12	170.21	2026-03-24
3133	894	6	72	72	154.57	2026-03-24
3134	895	16	24	24	158.33	2026-03-25
3135	895	15	36	36	166.81	2026-03-25
3136	895	35	36	36	122.6	2026-03-25
3137	895	39	6	6	31.87	2026-03-25
3138	896	15	24	24	170.21	2026-03-25
3139	896	4	12	12	37.77	2026-03-25
3140	896	25	6	6	171.1	2026-03-25
3141	897	2	12	12	102.24	2026-03-26
3142	897	33	12	12	114.93	2026-03-26
3143	897	39	18	18	31.87	2026-03-26
3144	897	38	12	12	152.33	2026-03-26
3145	898	4	12	12	37.77	2026-03-25
3146	898	32	18	18	124.18	2026-03-25
3147	899	29	6	6	46.38	2026-03-25
3148	899	7	6	0	156.76	\N
3149	899	6	24	24	151.48	2026-03-25
3150	899	9	72	72	127.29	2026-03-25
3151	900	20	18	18	68.61	2026-03-27
3152	900	1	6	6	12.49	2026-03-27
3153	900	8	6	6	49.81	2026-03-27
3154	901	26	6	6	52.75	2026-03-26
3155	901	5	72	72	105.48	2026-03-26
3156	901	34	12	12	128.16	2026-03-26
3157	902	21	48	48	59.84	2026-03-26
3158	902	15	12	12	170.21	2026-03-26
3159	902	17	12	12	53.01	2026-03-26
3160	903	10	24	24	73.41	2026-03-27
3161	903	26	18	18	54.42	2026-03-27
3162	903	31	48	48	147.43	2026-03-27
3163	904	34	12	12	134.91	2026-03-26
3164	904	15	12	12	170.21	2026-03-26
3165	904	1	12	12	12.49	2026-03-26
3166	905	23	12	12	46.91	2026-03-27
3167	905	40	12	12	38.67	2026-03-27
3168	905	10	48	48	74.91	2026-03-27
3169	905	27	24	24	17.24	2026-03-27
3170	906	4	36	36	37.77	2026-03-26
3171	906	39	12	12	32.52	2026-03-26
3172	906	37	72	72	129.57	2026-03-26
3173	907	35	36	36	122.6	2026-03-27
3174	907	2	12	12	102.24	2026-03-27
3175	907	19	48	48	150.51	2026-03-27
3176	907	26	18	18	54.42	2026-03-27
3177	908	24	48	48	36.72	2026-03-27
3178	908	31	48	48	150.44	2026-03-27
3179	909	38	36	36	155.44	2026-03-26
3180	909	6	48	48	154.57	2026-03-26
3181	909	23	36	36	46.91	2026-03-26
3182	909	10	48	48	74.91	2026-03-26
3183	909	31	48	48	150.44	2026-03-26
3184	910	9	48	48	129.89	2026-03-26
3185	910	32	6	6	124.18	2026-03-26
3186	910	31	24	24	150.44	2026-03-26
3187	911	9	72	72	123.4	2026-03-28
3188	911	37	48	48	123.09	2026-03-28
3189	911	36	24	24	113.56	2026-03-28
3190	912	12	48	48	145.58	2026-03-28
3191	912	16	12	12	161.56	2026-03-28
3192	912	18	48	48	82.83	2026-03-28
3193	912	26	6	6	55.53	2026-03-28
3194	912	38	36	36	155.44	2026-03-28
3195	913	11	6	6	191.14	2026-03-27
3196	913	6	24	24	151.48	2026-03-27
3197	914	31	24	24	150.44	2026-03-28
3198	914	3	36	36	26.74	2026-03-28
3199	914	37	24	24	129.57	2026-03-28
3200	914	29	18	18	47.33	2026-03-28
3201	914	38	24	24	155.44	2026-03-28
3202	915	29	6	6	47.33	2026-03-27
3203	915	26	18	18	55.53	2026-03-27
3204	915	2	18	18	104.33	2026-03-27
3205	915	12	48	48	145.58	2026-03-27
3206	916	31	72	63	150.44	2026-03-27
3207	916	9	72	72	129.89	2026-03-27
3208	916	6	48	48	154.57	2026-03-27
3209	916	1	6	6	12.49	2026-03-27
3210	917	5	24	24	105.48	2026-03-28
3211	917	13	24	24	92.66	2026-03-28
3212	917	36	48	48	113.56	2026-03-28
3213	918	16	36	36	153.48	2026-03-27
3214	918	9	24	24	123.4	2026-03-27
3215	919	11	6	6	185.29	2026-03-27
3216	919	6	72	72	146.84	2026-03-27
3217	920	33	6	6	111.42	2026-03-28
3218	920	38	24	24	147.67	2026-03-28
3219	921	8	18	18	49.81	2026-03-28
3220	921	31	72	72	150.44	2026-03-28
3221	921	36	48	48	119.54	2026-03-28
3222	921	34	36	36	134.91	2026-03-28
3223	921	26	6	6	55.53	2026-03-28
3224	922	19	48	48	153.58	2026-03-28
3225	922	25	6	6	171.1	2026-03-28
3226	922	24	24	24	36.72	2026-03-28
3227	922	9	72	72	129.89	2026-03-28
3228	922	40	18	18	38.67	2026-03-28
3229	923	4	12	12	35.88	2026-03-29
3230	923	26	6	6	52.75	2026-03-29
3231	924	37	24	24	126.98	2026-03-29
3232	924	5	72	72	108.81	2026-03-29
3233	924	3	12	12	26.21	2026-03-29
3234	924	31	72	72	147.43	2026-03-29
3235	925	21	24	24	56.85	2026-03-30
3236	925	3	36	36	25.4	2026-03-30
3237	926	31	48	0	150.44	\N
3238	926	30	48	48	184.29	2026-03-30
3239	926	23	36	12	46.91	2026-03-30
3240	927	17	18	18	51.95	2026-03-29
3241	927	37	48	48	126.98	2026-03-29
3242	927	2	18	18	102.24	2026-03-29
3243	927	36	72	72	117.15	2026-03-29
3244	928	18	72	72	81.17	2026-03-30
3245	928	4	24	24	37.01	2026-03-30
3246	928	37	24	24	126.98	2026-03-30
3247	928	8	12	12	48.81	2026-03-30
3248	929	6	48	48	154.57	2026-03-31
3249	929	37	24	24	129.57	2026-03-31
3250	929	9	48	48	129.89	2026-03-31
3251	929	14	24	24	116.19	2026-03-31
3252	930	30	48	48	175.08	2026-03-30
3253	930	13	24	24	92.66	2026-03-30
3254	931	17	12	12	51.95	2026-03-30
3255	931	13	36	36	95.59	2026-03-30
3256	932	12	48	48	142.67	2026-03-30
3257	932	2	12	12	102.24	2026-03-30
3258	932	8	6	6	48.81	2026-03-30
3259	933	24	24	24	34.88	2026-03-31
3260	933	3	12	0	25.4	\N
3261	934	27	24	24	17.24	2026-03-30
3262	934	9	72	72	129.89	2026-03-30
3263	934	12	72	72	145.58	2026-03-30
3264	934	31	24	0	150.44	\N
3265	935	2	6	6	102.24	2026-03-31
3266	935	4	24	24	37.01	2026-03-31
3267	936	39	6	6	32.52	2026-03-30
3268	936	37	72	72	129.57	2026-03-30
3269	936	6	72	72	154.57	2026-03-30
3270	937	37	24	24	129.57	2026-03-30
3271	937	38	12	12	155.44	2026-03-30
3272	937	12	48	48	145.58	2026-03-30
3273	937	8	18	18	49.81	2026-03-30
3274	938	2	6	6	104.33	2026-03-30
3275	938	33	12	12	117.28	2026-03-30
3276	939	36	48	48	117.15	2026-03-31
3277	939	6	48	48	151.48	2026-03-31
3278	939	4	24	24	37.01	2026-03-31
3279	939	24	24	24	35.99	2026-03-31
3280	939	19	48	48	150.51	2026-03-31
3281	940	19	72	72	150.51	2026-04-01
3282	940	18	24	24	81.17	2026-04-01
3283	940	27	24	24	16.9	2026-04-01
3284	940	29	6	6	46.38	2026-04-01
3285	940	26	6	6	54.42	2026-04-01
3286	941	30	72	72	184.29	2026-03-31
3287	941	7	6	6	159.96	2026-03-31
3288	941	3	24	0	26.74	\N
3289	942	21	48	48	58.64	2026-03-31
3290	942	4	12	12	37.01	2026-03-31
3291	943	33	18	18	114.93	2026-03-31
3292	943	38	24	24	152.33	2026-03-31
3293	943	11	18	18	191.14	2026-03-31
3294	943	20	6	6	67.24	2026-03-31
3295	943	2	12	12	102.24	2026-03-31
3296	944	17	12	12	50.36	2026-04-01
3297	944	24	48	48	34.88	2026-04-01
3298	945	33	18	18	111.42	2026-04-01
3299	945	12	48	48	138.3	2026-04-01
3300	945	37	24	24	123.09	2026-04-01
3301	945	34	36	36	128.16	2026-04-01
3302	945	40	6	6	36.74	2026-04-01
3303	946	16	36	36	158.33	2026-03-31
3304	946	20	6	6	67.24	2026-03-31
3305	946	35	24	24	122.6	2026-03-31
3306	947	16	24	24	158.33	2026-04-01
3307	947	39	18	18	31.87	2026-04-01
3308	947	37	24	24	126.98	2026-04-01
3309	947	26	6	6	54.42	2026-04-01
3310	948	23	12	12	46.91	2026-04-01
3311	948	36	48	48	119.54	2026-04-01
3312	948	30	72	72	184.29	2026-04-01
3313	949	4	24	24	37.77	2026-04-01
3314	949	2	6	6	104.33	2026-04-01
3315	950	5	72	72	108.81	2026-04-01
3316	950	37	48	48	126.98	2026-04-01
3317	950	16	36	36	158.33	2026-04-01
3318	950	23	12	0	45.97	\N
3319	950	14	24	24	113.87	2026-04-01
3320	951	15	12	12	161.7	2026-04-03
3321	951	16	24	24	153.48	2026-04-03
3322	951	40	6	6	36.74	2026-04-03
3323	952	5	72	72	111.03	2026-04-03
3324	952	9	48	48	129.89	2026-04-03
3325	953	39	18	18	31.87	2026-04-02
3326	953	30	48	48	180.6	2026-04-02
3327	953	2	12	12	102.24	2026-04-02
3328	954	16	12	12	161.56	2026-04-02
3329	954	23	12	0	46.91	\N
3330	955	5	48	48	111.03	2026-04-02
3331	955	12	48	48	145.58	2026-04-02
3332	956	9	72	72	127.29	2026-04-02
3333	956	16	24	24	158.33	2026-04-02
3334	957	31	24	24	142.92	2026-04-03
3335	957	36	24	11	113.56	2026-04-03
3336	957	9	24	24	123.4	2026-04-03
3337	958	8	18	18	49.81	2026-04-03
3338	958	5	24	24	111.03	2026-04-03
3339	958	4	36	36	37.77	2026-04-03
3340	959	2	12	12	102.24	2026-04-04
3341	959	15	12	12	166.81	2026-04-04
3342	960	21	72	72	59.84	2026-04-03
3343	960	37	48	48	129.57	2026-04-03
3344	960	20	6	6	68.61	2026-04-03
3345	960	24	48	48	36.72	2026-04-03
3346	961	9	48	48	127.29	2026-04-03
3347	961	14	12	12	113.87	2026-04-03
3348	961	39	18	18	31.87	2026-04-03
3349	961	16	12	12	158.33	2026-04-03
3350	961	35	24	24	122.6	2026-04-03
3351	962	3	24	24	26.21	2026-04-04
3352	962	38	24	24	152.33	2026-04-04
3353	962	33	18	18	114.93	2026-04-04
3354	962	12	24	24	142.67	2026-04-04
3355	962	27	12	12	16.9	2026-04-04
3356	963	12	24	24	145.58	2026-04-03
3357	963	17	6	6	53.01	2026-04-03
3358	964	31	72	72	142.92	2026-04-03
3359	964	3	12	12	25.4	2026-04-03
3360	964	20	18	18	65.18	2026-04-03
3361	964	2	12	12	99.11	2026-04-03
3362	964	1	6	6	11.87	2026-04-03
3363	965	2	12	12	104.33	2026-04-03
3364	965	35	12	12	125.1	2026-04-03
3365	965	19	72	72	153.58	2026-04-03
3366	966	10	72	72	71.16	2026-04-03
3367	966	33	6	6	111.42	2026-04-03
3368	966	23	36	0	44.56	\N
3369	966	14	12	12	110.38	2026-04-03
3370	966	15	36	36	161.7	2026-04-03
3371	967	2	6	6	104.33	2026-04-03
3372	967	24	72	72	36.72	2026-04-03
3373	967	14	24	24	116.19	2026-04-03
3374	967	6	48	0	154.57	\N
3375	967	31	48	48	150.44	2026-04-03
3376	968	26	18	18	52.75	2026-04-04
3377	968	31	24	24	142.92	2026-04-04
3378	968	12	24	24	138.3	2026-04-04
3379	969	13	36	36	97.54	2026-04-06
3380	969	12	48	48	145.58	2026-04-06
3381	969	31	48	48	150.44	2026-04-06
3382	969	2	18	18	104.33	2026-04-06
3383	969	25	12	12	171.1	2026-04-06
3384	970	27	12	12	17.24	2026-04-06
3385	970	19	72	72	153.58	2026-04-06
3386	971	3	24	24	25.4	2026-04-06
3387	971	15	36	36	161.7	2026-04-06
3388	971	12	48	48	138.3	2026-04-06
3389	971	17	12	12	50.36	2026-04-06
3390	972	31	24	24	150.44	2026-04-06
3391	972	26	6	6	55.53	2026-04-06
3392	972	20	18	18	68.61	2026-04-06
3393	972	37	48	48	129.57	2026-04-06
3394	973	16	24	24	158.33	2026-04-07
3395	973	25	18	18	167.68	2026-04-07
3396	973	26	18	18	54.42	2026-04-07
3397	974	6	24	24	154.57	2026-04-06
3398	974	9	24	24	129.89	2026-04-06
3399	975	8	6	6	47.32	2026-04-06
3400	975	6	48	0	146.84	\N
3401	975	4	24	24	35.88	2026-04-06
3402	975	3	12	12	25.4	2026-04-06
3403	975	38	36	36	147.67	2026-04-06
3404	976	33	12	12	117.28	2026-04-08
3405	976	6	72	72	154.57	2026-04-08
3406	977	5	72	72	111.03	2026-04-07
3407	977	37	72	72	129.57	2026-04-07
3408	977	25	18	18	171.1	2026-04-07
3409	978	31	24	24	150.44	2026-04-07
3410	978	14	24	24	116.19	2026-04-07
3411	978	6	24	24	154.57	2026-04-07
3412	978	15	12	12	170.21	2026-04-07
3413	978	9	24	24	129.89	2026-04-07
3414	979	33	12	12	117.28	2026-04-07
3415	979	5	48	48	111.03	2026-04-07
3416	980	33	12	12	117.28	2026-04-07
3417	980	2	12	12	104.33	2026-04-07
3418	980	17	6	6	53.01	2026-04-07
3419	981	31	24	24	147.43	2026-04-08
3420	981	35	12	12	122.6	2026-04-08
3421	981	8	18	18	48.81	2026-04-08
3422	981	6	48	48	151.48	2026-04-08
3423	981	11	6	6	191.14	2026-04-08
3424	982	4	36	36	35.88	2026-04-07
3425	982	2	12	12	99.11	2026-04-07
3426	982	23	36	36	44.56	2026-04-07
3427	982	27	12	12	16.38	2026-04-07
3428	982	39	12	12	30.89	2026-04-07
3429	983	38	24	24	155.44	2026-04-08
3430	983	24	72	72	36.72	2026-04-08
3431	983	9	24	24	129.89	2026-04-08
3432	984	38	24	24	155.44	2026-04-07
3433	984	3	24	24	26.74	2026-04-07
3434	985	16	12	12	161.56	2026-04-07
3435	985	4	12	12	37.77	2026-04-07
3436	985	39	18	18	32.52	2026-04-07
3437	985	18	24	24	82.83	2026-04-07
3438	986	14	12	12	110.38	2026-04-08
3439	986	4	36	36	35.88	2026-04-08
3440	986	16	24	24	153.48	2026-04-08
3441	986	39	6	6	30.89	2026-04-08
3442	987	18	48	48	81.17	2026-04-07
3443	987	4	36	36	37.01	2026-04-07
3444	987	6	72	0	151.48	\N
3445	987	37	24	24	126.98	2026-04-07
3446	988	2	6	6	102.24	2026-04-09
3447	988	21	72	48	58.64	2026-04-09
3448	988	4	24	24	37.01	2026-04-09
3449	989	12	48	48	138.3	2026-04-09
3450	989	25	12	12	162.54	2026-04-09
3451	989	24	48	48	34.88	2026-04-09
3452	989	6	48	48	146.84	2026-04-09
3453	990	37	48	48	126.98	2026-04-08
3454	990	9	72	64	127.29	2026-04-08
3455	990	1	12	12	12.24	2026-04-08
3456	990	15	12	12	166.81	2026-04-08
3457	991	29	12	12	47.33	2026-04-08
3458	991	11	6	6	195.04	2026-04-08
3459	992	22	12	12	165.43	2026-04-08
3460	992	12	24	24	145.58	2026-04-08
3461	992	39	18	18	32.52	2026-04-08
3462	992	1	12	12	12.49	2026-04-08
3463	992	4	36	36	37.77	2026-04-08
3464	993	12	48	48	145.58	2026-04-08
3465	993	19	72	72	153.58	2026-04-08
3466	993	6	24	0	154.57	\N
3467	994	6	24	0	151.48	\N
3468	994	21	72	72	58.64	2026-04-09
3469	994	35	36	36	122.6	2026-04-09
3470	994	5	24	24	108.81	2026-04-09
3471	995	4	24	24	37.77	2026-04-08
3472	995	32	12	12	124.18	2026-04-08
3473	995	17	6	6	53.01	2026-04-08
3474	995	31	72	72	150.44	2026-04-08
3475	995	16	24	24	161.56	2026-04-08
3476	996	25	18	6	167.68	2026-04-09
3477	996	33	6	6	114.93	2026-04-09
3478	996	31	72	72	147.43	2026-04-09
3479	997	27	36	24	16.38	2026-04-09
3480	997	36	72	0	113.56	\N
3481	997	31	72	72	142.92	2026-04-09
3482	997	13	24	24	92.66	2026-04-09
3483	997	2	12	12	99.11	2026-04-09
3484	998	17	6	6	53.01	2026-04-09
3485	998	31	48	48	150.44	2026-04-09
3486	998	38	36	36	155.44	2026-04-09
3487	998	20	12	12	68.61	2026-04-09
3488	998	39	12	12	32.52	2026-04-09
3489	999	4	12	12	37.77	2026-04-10
3490	999	38	24	24	155.44	2026-04-10
3491	999	26	18	18	55.53	2026-04-10
3492	1000	12	24	24	145.58	2026-04-09
3493	1000	6	72	72	154.57	2026-04-09
3494	1001	8	6	6	49.81	2026-04-10
3495	1001	22	18	18	165.43	2026-04-10
3496	1001	33	6	6	117.28	2026-04-10
3497	1001	31	72	72	150.44	2026-04-10
3498	1002	25	6	0	162.54	\N
3499	1002	2	18	18	99.11	2026-04-10
3500	1002	8	18	18	47.32	2026-04-10
3501	1003	1	18	18	12.24	2026-04-11
3502	1003	32	12	12	121.7	2026-04-11
3503	1004	16	12	12	161.56	2026-04-11
3504	1004	32	18	18	124.18	2026-04-11
3505	1004	2	18	18	104.33	2026-04-11
3506	1004	10	72	72	74.91	2026-04-11
3507	1005	26	18	18	55.53	2026-04-10
3508	1005	4	36	36	37.77	2026-04-10
3509	1006	30	48	24	175.08	2026-04-10
3510	1006	38	12	12	147.67	2026-04-10
3511	1006	12	24	24	138.3	2026-04-10
3512	1007	3	36	36	26.74	2026-04-10
3513	1007	16	12	12	161.56	2026-04-10
3514	1008	39	18	18	30.89	2026-04-11
3515	1008	24	48	48	34.88	2026-04-11
3516	1008	13	36	36	92.66	2026-04-11
3517	1008	3	24	24	25.4	2026-04-11
3518	1009	38	24	24	155.44	2026-04-10
3519	1009	12	72	72	145.58	2026-04-10
3520	1009	20	6	6	68.61	2026-04-10
3521	1010	14	24	24	113.87	2026-04-11
3522	1010	15	24	24	166.81	2026-04-11
3523	1011	16	12	12	161.56	2026-04-11
3524	1011	25	6	0	171.1	\N
3525	1011	4	24	24	37.77	2026-04-11
3526	1012	24	72	72	34.88	2026-04-12
3527	1012	6	48	48	146.84	2026-04-12
3528	1012	31	48	48	142.92	2026-04-12
3529	1012	23	36	36	44.56	2026-04-12
3530	1013	2	6	6	102.24	2026-04-12
3531	1013	24	72	72	35.99	2026-04-12
3532	1013	4	12	12	37.01	2026-04-12
3533	1014	38	36	36	155.44	2026-04-13
3534	1014	3	36	36	26.74	2026-04-13
3535	1014	11	6	6	195.04	2026-04-13
3536	1014	13	12	12	97.54	2026-04-13
3537	1015	16	24	24	161.56	2026-04-13
3538	1015	5	72	72	111.03	2026-04-13
3539	1015	8	12	12	49.81	2026-04-13
3540	1016	4	24	24	37.77	2026-04-13
3541	1016	24	48	48	36.72	2026-04-13
3542	1016	37	24	24	129.57	2026-04-13
3543	1016	7	6	6	159.96	2026-04-13
3544	1017	5	72	72	105.48	2026-04-13
3545	1017	14	12	12	110.38	2026-04-13
3546	1017	12	24	24	138.3	2026-04-13
3547	1018	4	36	36	35.88	2026-04-13
3548	1018	37	24	24	123.09	2026-04-13
3549	1019	31	24	24	150.44	2026-04-13
3550	1019	7	6	6	159.96	2026-04-13
3551	1020	5	24	24	111.03	2026-04-13
3552	1020	39	6	6	32.52	2026-04-13
3553	1020	26	6	5	55.53	2026-04-13
3554	1020	37	72	72	129.57	2026-04-13
3555	1021	26	18	0	54.42	\N
3556	1021	18	72	72	81.17	2026-04-13
3557	1021	12	72	72	142.67	2026-04-13
3558	1021	31	48	48	147.43	2026-04-13
3559	1021	38	24	24	152.33	2026-04-13
3560	1022	12	72	72	142.67	2026-04-13
3561	1022	26	12	0	54.42	\N
3562	1022	5	72	72	108.81	2026-04-13
3563	1023	16	24	24	161.56	2026-04-14
3564	1023	35	36	36	125.1	2026-04-14
3565	1023	31	48	48	150.44	2026-04-14
3566	1023	2	6	6	104.33	2026-04-14
3567	1024	13	12	12	97.54	2026-04-15
3568	1024	31	48	48	150.44	2026-04-15
3569	1025	8	6	6	49.81	2026-04-15
3570	1025	12	24	24	145.58	2026-04-15
3571	1025	29	12	12	47.33	2026-04-15
3572	1025	9	48	0	129.89	\N
3573	1026	37	24	24	123.09	2026-04-14
3574	1026	5	24	24	105.48	2026-04-14
3575	1026	2	18	18	99.11	2026-04-14
3576	1026	16	36	36	153.48	2026-04-14
3577	1026	26	18	18	52.75	2026-04-14
3578	1027	28	12	12	176.24	2026-04-14
3579	1027	14	12	12	116.19	2026-04-14
3580	1027	6	48	48	154.57	2026-04-14
3581	1028	34	36	36	132.21	2026-04-15
3582	1028	40	6	6	37.9	2026-04-15
3583	1028	25	18	18	167.68	2026-04-15
3584	1029	25	6	6	171.1	2026-04-14
3585	1029	37	48	48	129.57	2026-04-14
3586	1029	33	6	6	117.28	2026-04-14
3587	1029	12	48	48	145.58	2026-04-14
3588	1030	15	36	36	166.81	2026-04-15
3589	1030	30	48	0	180.6	\N
3590	1030	6	24	24	151.48	2026-04-15
3591	1030	4	12	12	37.01	2026-04-15
3592	1030	17	12	12	51.95	2026-04-15
3593	1031	31	24	24	147.43	2026-04-15
3594	1031	26	6	0	54.42	\N
3595	1032	30	48	0	175.08	\N
3596	1032	31	24	24	142.92	2026-04-14
3597	1032	17	18	18	50.36	2026-04-14
3598	1032	8	18	18	47.32	2026-04-14
3599	1032	16	36	36	153.48	2026-04-14
3600	1033	13	12	12	92.66	2026-04-14
3601	1033	37	48	48	123.09	2026-04-14
3602	1034	31	48	48	142.92	2026-04-14
3603	1034	12	24	24	138.3	2026-04-14
3604	1034	5	48	48	105.48	2026-04-14
3605	1034	4	36	24	35.88	2026-04-14
3606	1034	13	24	24	92.66	2026-04-14
3607	1035	37	72	72	123.09	2026-04-14
3608	1035	11	6	6	185.29	2026-04-14
3609	1035	20	6	6	65.18	2026-04-14
3610	1035	9	48	24	123.4	2026-04-14
3611	1035	31	48	48	142.92	2026-04-14
3612	1036	37	72	72	129.57	2026-04-14
3613	1036	21	48	48	59.84	2026-04-14
3614	1036	22	18	18	165.43	2026-04-14
3615	1037	25	12	12	171.1	2026-04-16
3616	1037	27	24	0	17.24	\N
3617	1037	29	12	12	47.33	2026-04-16
3618	1038	2	18	18	104.33	2026-04-15
3619	1038	39	18	18	32.52	2026-04-15
3620	1038	33	6	6	117.28	2026-04-15
3621	1038	38	36	36	155.44	2026-04-15
3622	1039	2	12	12	104.33	2026-04-15
3623	1039	31	24	24	150.44	2026-04-15
3624	1040	13	36	36	92.66	2026-04-16
3625	1040	2	12	12	99.11	2026-04-16
3626	1041	40	6	6	38.67	2026-04-16
3627	1041	25	18	18	171.1	2026-04-16
3628	1041	32	18	18	124.18	2026-04-16
3629	1041	16	36	36	161.56	2026-04-16
3630	1041	2	12	12	104.33	2026-04-16
3631	1042	7	6	6	159.96	2026-04-15
3632	1042	19	24	24	153.58	2026-04-15
3633	1042	39	12	12	32.52	2026-04-15
3634	1042	37	72	72	129.57	2026-04-15
3635	1043	9	48	0	127.29	\N
3636	1043	5	24	24	108.81	2026-04-16
3637	1043	24	24	24	35.99	2026-04-16
3638	1043	4	24	24	37.01	2026-04-16
3639	1043	20	18	18	67.24	2026-04-16
3640	1044	2	12	12	102.24	2026-04-17
3641	1044	39	12	12	31.87	2026-04-17
3642	1044	5	72	72	108.81	2026-04-17
3643	1044	31	24	24	147.43	2026-04-17
3644	1045	12	72	72	138.3	2026-04-16
3645	1045	25	12	12	162.54	2026-04-16
3646	1045	14	36	36	110.38	2026-04-16
3647	1045	37	72	72	123.09	2026-04-16
3648	1045	31	48	48	142.92	2026-04-16
3649	1046	5	72	72	108.81	2026-04-16
3650	1046	4	36	0	37.01	\N
3651	1046	25	12	12	167.68	2026-04-16
3652	1047	19	72	72	145.9	2026-04-16
3653	1047	4	24	0	35.88	\N
3654	1047	29	6	6	44.96	2026-04-16
3655	1047	30	72	0	175.08	\N
3656	1047	7	12	12	151.96	2026-04-16
3657	1048	12	48	48	142.67	2026-04-16
3658	1048	18	72	72	81.17	2026-04-16
3659	1048	36	48	48	117.15	2026-04-16
3660	1048	6	48	0	151.48	\N
3661	1048	16	24	24	158.33	2026-04-16
3662	1049	15	12	12	170.21	2026-04-16
3663	1049	3	12	12	26.74	2026-04-16
3664	1050	31	24	24	150.44	2026-04-16
3665	1050	18	48	48	82.83	2026-04-16
3666	1050	15	12	12	170.21	2026-04-16
3667	1051	31	24	24	142.92	2026-04-17
3668	1051	6	24	24	146.84	2026-04-17
3669	1052	31	48	48	150.44	2026-04-18
3670	1052	26	6	6	55.53	2026-04-18
3671	1052	5	24	24	111.03	2026-04-18
3672	1052	6	24	24	154.57	2026-04-18
3673	1052	40	6	6	38.67	2026-04-18
3674	1053	16	24	24	158.33	2026-04-17
3675	1053	17	12	12	51.95	2026-04-17
3676	1054	33	12	12	117.28	2026-04-17
3677	1054	23	24	24	46.91	2026-04-17
3678	1054	27	12	12	17.24	2026-04-17
3679	1055	9	24	0	127.29	\N
3680	1055	4	12	12	37.01	2026-04-17
3681	1055	31	24	24	147.43	2026-04-17
3682	1056	38	12	12	155.44	2026-04-17
3683	1056	20	6	6	68.61	2026-04-17
3684	1057	4	12	12	37.77	2026-04-17
3685	1057	19	48	48	153.58	2026-04-17
3686	1057	6	24	0	154.57	\N
3687	1058	8	6	6	49.81	2026-04-18
3688	1058	16	24	24	161.56	2026-04-18
3689	1058	38	36	36	155.44	2026-04-18
3690	1058	3	24	24	26.74	2026-04-18
3691	1058	9	48	0	129.89	\N
3692	1059	7	6	6	151.96	2026-04-18
3693	1059	23	24	24	44.56	2026-04-18
3694	1059	18	48	48	78.69	2026-04-18
3695	1060	39	12	12	32.52	2026-04-20
3696	1060	33	6	6	117.28	2026-04-20
3697	1060	5	48	48	111.03	2026-04-20
3698	1061	25	6	6	167.68	2026-04-19
3699	1061	16	36	36	158.33	2026-04-19
3700	1061	5	24	24	108.81	2026-04-19
3701	1061	15	36	36	166.81	2026-04-19
3702	1061	6	48	0	151.48	\N
3703	1062	14	36	3	110.38	2026-04-19
3704	1062	20	12	12	65.18	2026-04-19
3705	1062	4	24	24	35.88	2026-04-19
3706	1062	39	6	6	30.89	2026-04-19
3707	1062	37	72	72	123.09	2026-04-19
3708	1063	14	24	0	116.19	\N
3709	1063	24	72	72	36.72	2026-04-20
3710	1063	21	72	72	59.84	2026-04-20
3711	1063	35	12	12	125.1	2026-04-20
3712	1063	19	72	72	153.58	2026-04-20
3713	1064	36	72	72	113.56	2026-04-19
3714	1064	31	72	72	142.92	2026-04-19
3715	1065	18	24	0	82.83	\N
3716	1065	13	36	36	97.54	2026-04-21
3717	1065	25	6	6	171.1	2026-04-21
3718	1065	17	18	18	53.01	2026-04-21
3719	1065	27	12	12	17.24	2026-04-21
3720	1066	16	12	12	161.56	2026-04-20
3721	1066	33	12	12	117.28	2026-04-20
3722	1067	9	72	0	123.4	\N
3723	1067	22	12	12	157.16	2026-04-20
3724	1067	33	12	12	111.42	2026-04-20
3725	1067	12	72	72	138.3	2026-04-20
3726	1067	37	24	24	123.09	2026-04-20
3727	1068	24	24	24	36.72	2026-04-20
3728	1068	26	12	12	55.53	2026-04-20
3729	1068	37	24	24	129.57	2026-04-20
3730	1068	33	6	6	117.28	2026-04-20
3731	1069	17	18	7	51.95	2026-04-20
3732	1069	25	6	6	167.68	2026-04-20
3733	1069	31	24	24	147.43	2026-04-20
3734	1069	12	24	24	142.67	2026-04-20
3735	1069	38	24	24	152.33	2026-04-20
3736	1070	31	24	24	142.92	2026-04-20
3737	1070	21	24	24	56.85	2026-04-20
3738	1071	3	24	24	26.21	2026-04-21
3739	1071	17	12	12	51.95	2026-04-21
3740	1071	5	72	48	108.81	2026-04-21
3741	1072	8	12	12	49.81	2026-04-20
3742	1072	31	72	72	150.44	2026-04-20
3743	1073	40	12	12	36.74	2026-04-20
3744	1073	6	24	0	146.84	\N
3745	1073	20	18	18	65.18	2026-04-20
3746	1073	16	24	24	153.48	2026-04-20
3747	1074	22	12	12	157.16	2026-04-20
3748	1074	15	12	12	161.7	2026-04-20
3749	1074	24	24	24	34.88	2026-04-20
3750	1074	5	72	72	105.48	2026-04-20
3751	1075	7	12	12	159.96	2026-04-21
3752	1075	9	48	0	129.89	\N
3753	1075	31	24	24	150.44	2026-04-21
3754	1075	22	12	12	165.43	2026-04-21
3755	1075	26	6	6	55.53	2026-04-21
3756	1076	4	12	12	37.77	2026-04-21
3757	1076	9	48	0	129.89	\N
3758	1077	18	72	0	82.83	\N
3759	1077	34	12	12	134.91	2026-04-21
3760	1077	12	24	24	145.58	2026-04-21
3761	1078	2	6	6	104.33	2026-04-21
3762	1078	9	48	0	129.89	\N
3763	1078	16	24	24	161.56	2026-04-21
3764	1079	30	48	48	184.29	2026-04-22
3765	1079	15	12	12	170.21	2026-04-22
3766	1079	13	12	12	97.54	2026-04-22
3767	1080	30	48	48	175.08	2026-04-21
3768	1080	29	6	6	44.96	2026-04-21
3769	1080	11	12	12	185.29	2026-04-21
3770	1080	39	12	12	30.89	2026-04-21
3771	1081	16	24	24	161.56	2026-04-21
3772	1081	21	24	24	59.84	2026-04-21
3773	1082	12	72	72	145.58	2026-04-22
3774	1082	4	24	24	37.77	2026-04-22
3775	1082	32	6	6	124.18	2026-04-22
3776	1082	37	24	24	129.57	2026-04-22
3777	1083	8	6	6	49.81	2026-04-22
3778	1083	3	36	36	26.74	2026-04-22
3779	1083	39	12	12	32.52	2026-04-22
3780	1083	16	12	12	161.56	2026-04-22
3781	1083	17	12	0	53.01	\N
3782	1084	2	18	12	102.24	2026-04-23
3783	1084	37	48	48	126.98	2026-04-23
3784	1084	13	36	36	95.59	2026-04-23
3785	1084	18	24	0	81.17	\N
3786	1084	25	6	6	167.68	2026-04-23
3787	1085	16	36	36	153.48	2026-04-24
3788	1085	12	24	24	138.3	2026-04-24
3789	1085	4	12	12	35.88	2026-04-24
3790	1085	18	48	0	78.69	\N
3791	1086	37	24	24	123.09	2026-04-23
3792	1086	23	12	12	44.56	2026-04-23
3793	1086	31	72	72	142.92	2026-04-23
3794	1086	22	6	6	157.16	2026-04-23
3795	1087	31	24	24	150.44	2026-04-23
3796	1087	12	48	48	145.58	2026-04-23
3797	1088	4	24	24	37.77	2026-04-23
3798	1088	17	12	12	53.01	2026-04-23
3799	1088	37	72	72	129.57	2026-04-23
3800	1089	24	48	48	36.72	2026-04-23
3801	1089	8	6	6	49.81	2026-04-23
3802	1089	22	18	18	165.43	2026-04-23
3803	1089	7	6	6	159.96	2026-04-23
3804	1090	5	72	72	111.03	2026-04-25
3805	1090	35	36	36	125.1	2026-04-25
3806	1091	12	48	48	145.58	2026-04-24
3807	1091	31	48	48	150.44	2026-04-24
3808	1091	22	18	18	165.43	2026-04-24
3809	1091	15	24	24	170.21	2026-04-24
3810	1091	17	12	0	53.01	\N
3811	1092	30	24	24	184.29	2026-04-24
3812	1092	5	48	0	111.03	\N
3813	1092	25	6	6	171.1	2026-04-24
3814	1093	13	24	24	95.59	2026-04-25
3815	1093	21	48	48	58.64	2026-04-25
3816	1094	13	12	12	95.59	2026-04-24
3817	1094	6	24	24	151.48	2026-04-24
3818	1094	24	48	48	35.99	2026-04-24
3819	1094	37	72	72	126.98	2026-04-24
3820	1094	12	72	72	142.67	2026-04-24
3821	1095	4	36	36	37.77	2026-04-24
3822	1095	5	48	48	111.03	2026-04-24
3823	1095	38	12	12	155.44	2026-04-24
3824	1095	25	6	6	171.1	2026-04-24
3825	1096	14	24	24	116.19	2026-04-26
3826	1096	11	6	6	195.04	2026-04-26
3827	1096	29	12	12	47.33	2026-04-26
3828	1096	30	24	24	184.29	2026-04-26
3829	1097	3	24	24	26.74	2026-04-25
3830	1097	15	36	36	170.21	2026-04-25
3831	1098	39	6	6	30.89	2026-04-25
3832	1098	2	18	18	99.11	2026-04-25
3833	1098	15	24	24	161.7	2026-04-25
3834	1098	32	6	6	117.97	2026-04-25
3835	1098	38	36	36	147.67	2026-04-25
3836	1099	12	24	24	138.3	2026-04-26
3837	1099	20	6	6	65.18	2026-04-26
3838	1099	9	72	0	123.4	\N
3839	1100	37	24	24	129.57	2026-04-27
3840	1100	31	48	48	150.44	2026-04-27
3841	1100	2	18	0	104.33	\N
3842	1100	38	36	36	155.44	2026-04-27
3843	1100	23	24	24	46.91	2026-04-27
3844	1101	24	24	24	34.88	2026-04-26
3845	1101	1	18	18	11.87	2026-04-26
3846	1101	37	48	48	123.09	2026-04-26
3847	1101	6	24	24	146.84	2026-04-26
3848	1101	5	24	24	105.48	2026-04-26
3849	1102	27	12	12	16.38	2026-04-26
3850	1102	29	18	18	44.96	2026-04-26
3851	1103	39	6	6	31.87	2026-04-28
3852	1103	33	6	6	114.93	2026-04-28
3853	1104	9	24	24	129.89	2026-04-27
3854	1104	28	24	24	176.24	2026-04-27
3855	1104	16	24	24	161.56	2026-04-27
3856	1104	22	12	12	165.43	2026-04-27
3857	1105	4	12	12	37.77	2026-04-27
3858	1105	1	6	6	12.49	2026-04-27
3859	1106	31	24	24	150.44	2026-04-28
3860	1106	16	24	24	161.56	2026-04-28
3861	1107	38	36	36	155.44	2026-04-29
3862	1107	39	6	6	32.52	2026-04-29
3863	1107	15	12	12	170.21	2026-04-29
3864	1108	39	12	12	30.89	2026-04-29
3865	1108	38	12	12	147.67	2026-04-29
3866	1108	40	18	18	36.74	2026-04-29
3867	1108	35	36	36	118.84	2026-04-29
3868	1109	21	24	0	56.85	\N
3869	1109	8	12	12	47.32	2026-04-28
3870	1109	12	24	24	138.3	2026-04-28
3871	1109	9	72	0	123.4	\N
3872	1110	21	24	0	59.84	\N
3873	1110	16	36	36	161.56	2026-04-28
3874	1110	9	48	0	129.89	\N
3875	1111	38	12	12	155.44	2026-04-30
3876	1111	14	36	36	116.19	2026-04-30
3877	1112	16	36	36	153.48	2026-04-29
3878	1112	3	12	12	25.4	2026-04-29
3879	1113	14	36	36	113.87	2026-04-30
3880	1113	39	6	6	31.87	2026-04-30
3881	1114	37	48	48	129.57	2026-04-29
3882	1114	17	12	12	53.01	2026-04-29
3883	1114	26	18	18	55.53	2026-04-29
3884	1114	36	24	24	119.54	2026-04-29
3885	1114	20	6	6	68.61	2026-04-29
3886	1115	32	6	6	124.18	2026-04-29
3887	1115	23	36	36	46.91	2026-04-29
3888	1116	33	18	18	117.28	2026-04-29
3889	1116	31	72	72	150.44	2026-04-29
3890	1117	16	24	24	153.48	2026-04-29
3891	1117	1	18	18	11.87	2026-04-29
3892	1117	9	48	0	123.4	\N
3893	1118	19	48	48	153.58	2026-04-30
3894	1118	37	72	72	129.57	2026-04-30
3895	1118	16	12	12	161.56	2026-04-30
3896	1118	13	12	12	97.54	2026-04-30
3897	1118	40	6	6	38.67	2026-04-30
3898	1119	37	72	72	123.09	2026-04-30
3899	1119	2	18	0	99.11	\N
3900	1120	23	12	12	44.56	2026-04-30
3901	1120	20	6	6	65.18	2026-04-30
3902	1121	32	12	12	124.18	2026-04-30
3903	1121	27	24	24	17.24	2026-04-30
3904	1121	4	12	12	37.77	2026-04-30
3905	1122	23	36	36	46.91	2026-04-30
3906	1122	24	72	72	36.72	2026-04-30
3907	1123	24	72	72	34.88	2026-04-30
3908	1123	25	12	12	162.54	2026-04-30
3909	1123	39	12	12	30.89	2026-04-30
3910	1124	10	72	72	74.91	2026-05-01
3911	1124	39	12	12	32.52	2026-05-01
3912	1124	12	72	72	145.58	2026-05-01
3913	1124	38	12	12	155.44	2026-05-01
3914	1125	29	18	18	46.38	2026-05-01
3915	1125	1	6	6	12.24	2026-05-01
3916	1125	5	24	24	108.81	2026-05-01
3917	1125	15	12	12	166.81	2026-05-01
3918	1126	16	24	24	153.48	2026-05-01
3919	1126	8	12	12	47.32	2026-05-01
3920	1126	23	36	36	44.56	2026-05-01
3921	1126	3	24	24	25.4	2026-05-01
3922	1127	24	24	24	35.99	2026-05-02
3923	1127	25	12	12	167.68	2026-05-02
3924	1127	37	24	24	126.98	2026-05-02
3925	1128	4	36	36	37.77	2026-05-01
3926	1128	39	18	18	32.52	2026-05-01
3927	1128	27	24	24	17.24	2026-05-01
3928	1129	8	6	6	47.32	2026-05-01
3929	1129	2	18	18	99.11	2026-05-01
3930	1129	34	36	36	128.16	2026-05-01
3931	1130	8	18	18	48.81	2026-05-01
3932	1130	10	48	48	73.41	2026-05-01
3933	1130	40	12	12	37.9	2026-05-01
3934	1131	37	24	24	123.09	2026-05-01
3935	1131	31	24	24	142.92	2026-05-01
3936	1131	21	24	24	56.85	2026-05-01
3937	1131	4	12	12	35.88	2026-05-01
3938	1131	16	36	36	153.48	2026-05-01
3939	1132	32	12	12	124.18	2026-05-02
3940	1132	3	24	24	26.74	2026-05-02
3941	1133	31	72	72	150.44	2026-05-02
3942	1133	3	24	24	26.74	2026-05-02
3943	1133	16	24	24	161.56	2026-05-02
3944	1133	39	6	6	32.52	2026-05-02
3945	1134	3	36	36	26.74	2026-05-03
3946	1134	5	72	72	111.03	2026-05-03
3947	1134	37	48	48	129.57	2026-05-03
3948	1134	24	72	72	36.72	2026-05-03
3949	1135	12	72	72	138.3	2026-05-04
3950	1135	13	12	12	92.66	2026-05-04
3951	1136	32	6	6	124.18	2026-05-04
3952	1136	26	12	12	55.53	2026-05-04
3953	1136	18	24	24	82.83	2026-05-04
3954	1137	16	36	36	153.48	2026-05-05
3955	1137	31	72	72	142.92	2026-05-05
3956	1137	30	48	48	175.08	2026-05-05
3957	1137	12	72	72	138.3	2026-05-05
3958	1137	26	18	18	52.75	2026-05-05
3959	1138	36	48	48	117.15	2026-05-05
3960	1138	14	12	12	113.87	2026-05-05
3961	1138	5	48	48	108.81	2026-05-05
3962	1138	30	48	48	180.6	2026-05-05
3963	1138	13	12	12	95.59	2026-05-05
3964	1139	12	72	72	145.58	2026-05-04
3965	1139	5	72	72	111.03	2026-05-04
3966	1139	15	12	12	170.21	2026-05-04
3967	1139	31	24	24	150.44	2026-05-04
3968	1140	9	72	72	123.4	2026-05-04
3969	1140	6	48	48	146.84	2026-05-04
3970	1140	35	36	36	118.84	2026-05-04
3971	1141	15	12	12	170.21	2026-05-05
3972	1141	33	12	12	117.28	2026-05-05
3973	1141	37	24	24	129.57	2026-05-05
3974	1141	32	18	18	124.18	2026-05-05
3975	1142	8	6	6	48.81	2026-05-05
3976	1142	12	72	72	142.67	2026-05-05
3977	1142	21	72	72	58.64	2026-05-05
3978	1142	39	18	18	31.87	2026-05-05
3979	1143	22	6	6	165.43	2026-05-06
3980	1143	9	48	48	129.89	2026-05-06
3981	1143	4	12	12	37.77	2026-05-06
3982	1144	2	12	12	102.24	2026-05-05
3983	1144	26	12	12	54.42	2026-05-05
3984	1145	18	48	48	82.83	2026-05-05
3985	1145	20	12	12	68.61	2026-05-05
3986	1146	34	36	36	134.91	2026-05-07
3987	1146	29	12	12	47.33	2026-05-07
3988	1146	4	36	36	37.77	2026-05-07
3989	1146	16	36	36	161.56	2026-05-07
3990	1146	30	24	24	184.29	2026-05-07
3991	1147	38	12	12	147.67	2026-05-06
3992	1147	27	12	12	16.38	2026-05-06
3993	1147	4	12	12	35.88	2026-05-06
3994	1147	24	48	48	34.88	2026-05-06
3995	1147	10	24	24	71.16	2026-05-06
3996	1148	4	12	12	37.01	2026-05-06
3997	1148	29	6	6	46.38	2026-05-06
3998	1148	16	36	36	158.33	2026-05-06
3999	1149	37	48	48	123.09	2026-05-06
4000	1149	6	48	48	146.84	2026-05-06
4001	1149	10	48	48	71.16	2026-05-06
4002	1150	3	36	36	26.74	2026-05-06
4003	1150	31	24	24	150.44	2026-05-06
4004	1150	34	12	12	134.91	2026-05-06
4005	1150	16	12	12	161.56	2026-05-06
4006	1151	6	72	72	154.57	2026-05-07
4007	1151	15	12	12	170.21	2026-05-07
4008	1151	32	12	12	124.18	2026-05-07
4009	1151	31	48	48	150.44	2026-05-07
4010	1152	31	72	72	150.44	2026-05-08
4011	1152	27	36	36	17.24	2026-05-08
4012	1153	25	12	12	162.54	2026-05-07
4013	1153	4	12	12	35.88	2026-05-07
4014	1153	20	12	12	65.18	2026-05-07
4015	1154	37	24	24	129.57	2026-05-08
4016	1154	30	24	24	184.29	2026-05-08
4017	1154	18	48	48	82.83	2026-05-08
4018	1154	10	24	24	74.91	2026-05-08
4019	1154	3	24	24	26.74	2026-05-08
4020	1155	15	36	36	170.21	2026-05-07
4021	1155	40	18	18	38.67	2026-05-07
4022	1155	31	72	72	150.44	2026-05-07
4023	1156	27	24	24	17.24	2026-05-07
4024	1156	12	72	72	145.58	2026-05-07
4025	1156	38	12	12	155.44	2026-05-07
4026	1156	18	72	72	82.83	2026-05-07
4027	1157	21	48	48	59.84	2026-05-08
4028	1157	23	36	36	46.91	2026-05-08
4029	1158	8	18	18	49.81	2026-05-07
4030	1158	12	24	24	145.58	2026-05-07
4031	1158	3	12	12	26.74	2026-05-07
4032	1158	14	36	36	116.19	2026-05-07
4033	1158	38	12	12	155.44	2026-05-07
4034	1159	32	18	18	117.97	2026-05-07
4035	1159	30	24	24	175.08	2026-05-07
4036	1160	8	18	18	49.81	2026-05-08
4037	1160	12	72	72	145.58	2026-05-08
4038	1161	8	18	6	47.32	2026-05-08
4039	1161	4	36	36	35.88	2026-05-08
4040	1161	3	36	36	25.4	2026-05-08
4041	1161	23	36	36	44.56	2026-05-08
4042	1161	25	18	18	162.54	2026-05-08
4043	1162	20	6	6	68.61	2026-05-08
4044	1162	9	24	24	129.89	2026-05-08
4045	1162	31	48	48	150.44	2026-05-08
4046	1162	35	12	12	125.1	2026-05-08
4047	1162	15	36	36	170.21	2026-05-08
4048	1163	12	72	72	142.67	2026-05-08
4049	1163	6	72	72	151.48	2026-05-08
4050	1163	3	24	24	26.21	2026-05-08
4051	1163	5	72	72	108.81	2026-05-08
4052	1163	29	12	12	46.38	2026-05-08
4053	1164	30	48	48	184.29	2026-05-08
4054	1164	36	48	48	119.54	2026-05-08
4055	1164	1	12	12	12.49	2026-05-08
4056	1165	31	48	48	150.44	2026-05-08
4057	1165	5	48	48	111.03	2026-05-08
4058	1165	38	24	24	155.44	2026-05-08
4059	1165	16	24	24	161.56	2026-05-08
4060	1165	25	18	18	171.1	2026-05-08
4061	1166	13	36	36	92.66	2026-05-09
4062	1166	6	48	48	146.84	2026-05-09
4063	1166	36	72	72	113.56	2026-05-09
4064	1166	23	36	36	44.56	2026-05-09
4065	1167	7	18	18	159.96	2026-05-09
4066	1167	12	48	48	145.58	2026-05-09
4067	1167	9	24	24	129.89	2026-05-09
4068	1167	25	6	6	171.1	2026-05-09
4069	1168	4	24	24	37.01	2026-05-09
4070	1168	13	24	24	95.59	2026-05-09
4071	1169	38	24	24	147.67	2026-05-10
4072	1169	1	18	18	11.87	2026-05-10
4073	1169	6	48	48	146.84	2026-05-10
4074	1169	17	6	6	50.36	2026-05-10
4075	1169	31	48	48	142.92	2026-05-10
4076	1170	4	24	24	37.77	2026-05-09
4077	1170	15	36	36	170.21	2026-05-09
4078	1171	31	24	24	150.44	2026-05-09
4079	1171	1	18	18	12.49	2026-05-09
4080	1171	38	12	12	155.44	2026-05-09
4081	1172	18	48	48	78.69	2026-05-09
4082	1172	16	24	24	153.48	2026-05-09
4083	1172	1	12	12	11.87	2026-05-09
4084	1173	9	72	72	123.4	2026-05-09
4085	1173	37	72	72	123.09	2026-05-09
4086	1173	24	24	24	34.88	2026-05-09
4087	1173	17	18	18	50.36	2026-05-09
4088	1174	2	12	12	99.11	2026-05-12
4089	1174	37	48	48	123.09	2026-05-12
4090	1174	16	12	12	153.48	2026-05-12
4091	1174	30	72	0	175.08	\N
4092	1174	6	24	24	146.84	2026-05-12
4093	1175	22	18	18	165.43	2026-05-12
4094	1175	16	12	12	161.56	2026-05-12
4095	1175	34	24	24	134.91	2026-05-12
4096	1175	30	72	0	184.29	\N
4097	1175	9	48	48	129.89	2026-05-12
4098	1176	11	12	12	185.29	2026-05-11
4099	1176	12	48	48	138.3	2026-05-11
4100	1177	4	36	36	37.77	2026-05-12
4101	1177	14	36	36	116.19	2026-05-12
4102	1177	18	72	72	82.83	2026-05-12
4103	1178	21	24	24	59.84	2026-05-12
4104	1178	33	12	12	117.28	2026-05-12
4105	1178	8	18	0	49.81	\N
4106	1178	1	12	12	12.49	2026-05-12
4107	1179	3	36	36	26.74	2026-05-11
4108	1179	31	24	24	150.44	2026-05-11
4109	1179	38	36	36	155.44	2026-05-11
4110	1180	23	12	12	46.91	2026-05-13
4111	1180	35	12	12	125.1	2026-05-13
4112	1180	5	24	24	111.03	2026-05-13
4113	1180	31	72	72	150.44	2026-05-13
4114	1180	25	6	6	171.1	2026-05-13
4115	1181	31	72	72	150.44	2026-05-12
4116	1181	16	36	36	161.56	2026-05-12
4117	1181	6	24	24	154.57	2026-05-12
4118	1181	5	24	24	111.03	2026-05-12
4119	1182	3	12	12	26.74	2026-05-12
4120	1182	33	12	12	117.28	2026-05-12
4121	1182	31	48	48	150.44	2026-05-12
4122	1183	29	12	12	47.33	2026-05-12
4123	1183	27	36	36	17.24	2026-05-12
4124	1183	1	12	12	12.49	2026-05-12
4125	1183	38	24	24	155.44	2026-05-12
4126	1183	10	24	24	74.91	2026-05-12
4127	1184	24	24	24	34.88	2026-05-12
4128	1184	31	48	48	142.92	2026-05-12
4129	1184	35	12	12	118.84	2026-05-12
4130	1185	40	6	6	38.67	2026-05-13
4131	1185	26	12	12	55.53	2026-05-13
4132	1186	5	24	24	111.03	2026-05-14
4133	1186	38	36	36	155.44	2026-05-14
4134	1186	18	72	72	82.83	2026-05-14
4135	1187	37	48	48	126.98	2026-05-13
4136	1187	11	18	18	191.14	2026-05-13
4137	1188	31	48	48	150.44	2026-05-13
4138	1188	5	72	72	111.03	2026-05-13
4139	1188	24	72	72	36.72	2026-05-13
4140	1189	12	48	48	142.67	2026-05-13
4141	1189	31	24	24	147.43	2026-05-13
4142	1189	27	12	12	16.9	2026-05-13
4143	1190	36	72	72	119.54	2026-05-14
4144	1190	32	6	6	124.18	2026-05-14
4145	1190	29	12	12	47.33	2026-05-14
4146	1190	14	24	24	116.19	2026-05-14
4147	1190	12	48	48	145.58	2026-05-14
4148	1191	29	18	18	47.33	2026-05-14
4149	1191	12	48	24	145.58	2026-05-14
4150	1191	31	24	24	150.44	2026-05-14
4151	1191	16	36	36	161.56	2026-05-14
4152	1191	38	24	24	155.44	2026-05-14
4153	1192	8	12	0	49.81	\N
4154	1192	33	12	12	117.28	2026-05-13
4155	1192	6	48	48	154.57	2026-05-13
4156	1193	13	24	24	92.66	2026-05-14
4157	1193	33	12	12	111.42	2026-05-14
4158	1194	38	24	24	155.44	2026-05-14
4159	1194	6	24	24	154.57	2026-05-14
4160	1194	11	6	6	195.04	2026-05-14
4161	1195	31	72	72	142.92	2026-05-14
4162	1195	27	36	36	16.38	2026-05-14
4163	1195	6	72	72	146.84	2026-05-14
4164	1195	30	72	0	175.08	\N
4165	1195	16	12	12	153.48	2026-05-14
4166	1196	4	12	12	37.77	2026-05-15
4167	1196	14	36	36	116.19	2026-05-15
4168	1196	27	24	24	17.24	2026-05-15
4169	1196	26	18	18	55.53	2026-05-15
4170	1197	2	18	18	102.24	2026-05-15
4171	1197	17	18	18	51.95	2026-05-15
4172	1197	15	36	36	166.81	2026-05-15
4173	1198	8	12	0	49.81	\N
4174	1198	31	24	24	150.44	2026-05-15
4175	1199	4	36	36	35.88	2026-05-15
4176	1199	16	24	24	153.48	2026-05-15
4177	1199	25	6	6	162.54	2026-05-15
4178	1200	13	36	36	97.54	2026-05-15
4179	1200	39	18	18	32.52	2026-05-15
4180	1200	33	6	6	117.28	2026-05-15
4181	1201	31	24	24	150.44	2026-05-16
4182	1201	33	12	12	117.28	2026-05-16
4183	1201	39	18	18	32.52	2026-05-16
4184	1201	22	18	18	165.43	2026-05-16
4185	1201	12	72	72	145.58	2026-05-16
4186	1202	38	36	36	147.67	2026-05-15
4187	1202	7	6	6	151.96	2026-05-15
4188	1203	11	12	12	195.04	2026-05-16
4189	1203	26	18	18	55.53	2026-05-16
4190	1204	39	18	18	30.89	2026-05-15
4191	1204	1	18	18	11.87	2026-05-15
4192	1204	31	72	72	142.92	2026-05-15
4193	1205	15	36	36	166.81	2026-05-15
4194	1205	23	36	24	45.97	2026-05-15
4195	1205	21	24	24	58.64	2026-05-15
4196	1205	14	36	36	113.87	2026-05-15
4197	1205	16	36	36	158.33	2026-05-15
4198	1206	12	48	48	138.3	2026-05-15
4199	1206	31	48	48	142.92	2026-05-15
4200	1206	25	12	12	162.54	2026-05-15
4201	1207	38	36	36	147.67	2026-05-15
4202	1207	2	18	18	99.11	2026-05-15
4203	1207	3	12	12	25.4	2026-05-15
4204	1207	23	12	0	44.56	\N
4205	1208	33	18	18	114.93	2026-05-15
4206	1208	13	24	24	95.59	2026-05-15
4207	1208	19	72	72	150.51	2026-05-15
4208	1208	38	12	12	152.33	2026-05-15
4209	1208	4	24	24	37.01	2026-05-15
4210	1209	15	36	36	170.21	2026-05-15
4211	1209	39	6	6	32.52	2026-05-15
4212	1210	39	18	18	32.52	2026-05-15
4213	1210	16	24	24	161.56	2026-05-15
4214	1211	17	18	18	51.95	2026-05-16
4215	1211	12	24	24	142.67	2026-05-16
4216	1211	37	24	24	126.98	2026-05-16
4217	1212	12	72	72	142.67	2026-05-17
4218	1212	14	12	12	113.87	2026-05-17
4219	1212	40	18	18	37.9	2026-05-17
4220	1212	31	48	48	147.43	2026-05-17
4221	1212	39	18	18	31.87	2026-05-17
4222	1213	13	12	12	97.54	2026-05-17
4223	1213	30	72	0	184.29	\N
4224	1213	2	18	18	104.33	2026-05-17
4225	1214	1	18	18	12.49	2026-05-18
4226	1214	31	24	24	150.44	2026-05-18
4227	1214	28	36	36	176.24	2026-05-18
4228	1214	39	18	18	32.52	2026-05-18
4229	1215	4	12	12	37.01	2026-05-18
4230	1215	24	48	48	35.99	2026-05-18
4231	1215	31	72	72	147.43	2026-05-18
4232	1215	23	12	12	45.97	2026-05-18
4233	1216	37	72	72	129.57	2026-05-18
4234	1216	11	6	6	195.04	2026-05-18
4235	1216	16	36	36	161.56	2026-05-18
4236	1217	10	48	48	74.91	2026-05-18
4237	1217	31	72	72	150.44	2026-05-18
4238	1218	26	6	6	54.42	2026-05-18
4239	1218	3	36	36	26.21	2026-05-18
4240	1218	33	18	18	114.93	2026-05-18
4241	1218	30	72	0	180.6	\N
4242	1218	16	12	12	158.33	2026-05-18
4243	1219	12	48	48	145.58	2026-05-19
4244	1219	30	48	0	184.29	\N
4245	1219	23	24	24	46.91	2026-05-19
4246	1220	8	18	18	49.81	2026-05-19
4247	1220	20	12	12	68.61	2026-05-19
4248	1220	2	12	12	104.33	2026-05-19
4249	1220	1	6	6	12.49	2026-05-19
4250	1221	20	18	18	68.61	2026-05-19
4251	1221	16	24	24	161.56	2026-05-19
4252	1221	5	48	48	111.03	2026-05-19
4253	1222	13	36	36	92.66	2026-05-18
4254	1222	20	12	12	65.18	2026-05-18
4255	1222	39	6	6	30.89	2026-05-18
4256	1222	15	36	36	161.7	2026-05-18
4257	1223	16	36	36	153.48	2026-05-18
4258	1223	14	36	36	110.38	2026-05-18
4259	1224	31	72	72	150.44	2026-05-19
4260	1224	1	6	6	12.49	2026-05-19
4261	1224	8	18	0	49.81	\N
4262	1224	5	24	24	111.03	2026-05-19
4263	1225	35	12	12	125.1	2026-05-19
4264	1225	31	48	48	150.44	2026-05-19
4265	1225	12	24	24	145.58	2026-05-19
4266	1226	23	36	36	46.91	2026-05-19
4267	1226	12	24	24	145.58	2026-05-19
4268	1226	37	24	24	129.57	2026-05-19
4269	1226	11	6	6	195.04	2026-05-19
4270	1227	5	48	48	111.03	2026-05-19
4271	1227	13	12	12	97.54	2026-05-19
4272	1227	31	48	48	150.44	2026-05-19
4273	1227	38	12	12	155.44	2026-05-19
4274	1227	37	24	24	129.57	2026-05-19
4275	1228	14	24	24	116.19	2026-05-20
4276	1228	31	72	72	150.44	2026-05-20
4277	1228	12	24	24	145.58	2026-05-20
4278	1228	37	24	24	129.57	2026-05-20
4279	1228	13	12	12	97.54	2026-05-20
4280	1229	9	24	24	129.89	2026-05-19
4281	1229	24	48	48	36.72	2026-05-19
4282	1230	3	24	24	26.74	2026-05-19
4283	1230	20	6	6	68.61	2026-05-19
4284	1230	2	12	12	104.33	2026-05-19
4285	1230	26	6	6	55.53	2026-05-19
4286	1231	23	12	0	46.91	\N
4287	1231	30	24	24	184.29	2026-05-20
4288	1232	21	48	48	59.84	2026-05-19
4289	1232	6	72	72	154.57	2026-05-19
4290	1233	9	24	24	127.29	2026-05-21
4291	1233	34	36	36	132.21	2026-05-21
4292	1234	1	18	18	12.24	2026-05-21
4293	1234	19	24	24	150.51	2026-05-21
4294	1234	12	48	48	142.67	2026-05-21
4295	1235	2	12	12	104.33	2026-05-20
4296	1235	12	24	24	145.58	2026-05-20
4297	1236	37	24	24	129.57	2026-05-20
4298	1236	16	12	12	161.56	2026-05-20
4299	1237	16	24	24	161.56	2026-05-20
4300	1237	10	24	24	74.91	2026-05-20
4301	1237	5	24	24	111.03	2026-05-20
4302	1237	2	12	12	104.33	2026-05-20
4303	1237	29	18	18	47.33	2026-05-20
4304	1238	6	72	72	154.57	2026-05-20
4305	1238	16	24	24	161.56	2026-05-20
4306	1238	31	48	48	150.44	2026-05-20
4307	1239	16	12	12	161.56	2026-05-20
4308	1239	10	48	48	74.91	2026-05-20
4309	1240	32	12	12	124.18	2026-05-20
4310	1240	2	6	6	104.33	2026-05-20
4311	1240	5	24	24	111.03	2026-05-20
4312	1240	9	48	48	129.89	2026-05-20
4313	1241	2	18	18	104.33	2026-05-20
4314	1241	10	48	7	74.91	2026-05-20
4315	1241	33	18	18	117.28	2026-05-20
4316	1241	4	36	36	37.77	2026-05-20
4317	1241	3	12	12	26.74	2026-05-20
4318	1242	5	48	48	111.03	2026-05-21
4319	1242	13	36	36	97.54	2026-05-21
4320	1242	24	72	72	36.72	2026-05-21
4321	1243	31	72	72	150.44	2026-05-21
4322	1243	6	48	48	154.57	2026-05-21
4323	1244	18	48	37	82.83	2026-05-21
4324	1244	31	72	72	150.44	2026-05-21
4325	1244	39	12	12	32.52	2026-05-21
4326	1244	25	6	6	171.1	2026-05-21
4327	1244	14	24	24	116.19	2026-05-21
4328	1245	2	6	6	104.33	2026-05-22
4329	1245	26	18	18	55.53	2026-05-22
4330	1245	38	12	12	155.44	2026-05-22
4331	1245	17	12	12	53.01	2026-05-22
4332	1245	31	48	48	150.44	2026-05-22
4333	1246	12	24	24	142.67	2026-05-21
4334	1246	22	18	18	162.12	2026-05-21
4335	1246	1	6	6	12.24	2026-05-21
4336	1247	1	12	12	12.49	2026-05-21
4337	1247	31	48	48	150.44	2026-05-21
4338	1248	32	6	6	121.7	2026-05-22
4339	1248	4	24	24	37.01	2026-05-22
4340	1248	29	12	12	46.38	2026-05-22
4341	1249	35	24	24	125.1	2026-05-22
4342	1249	26	18	0	55.53	\N
4343	1250	30	24	0	184.29	\N
4344	1250	26	18	0	55.53	\N
4345	1250	6	48	48	154.57	2026-05-21
4346	1251	3	36	0	26.74	\N
4347	1251	6	48	48	154.57	2026-05-21
4348	1251	25	18	18	171.1	2026-05-21
4349	1251	21	72	24	59.84	2026-05-21
4350	1252	2	6	6	104.33	2026-05-22
4351	1252	23	36	36	46.91	2026-05-22
4352	1252	26	12	12	55.53	2026-05-22
4353	1252	25	18	18	171.1	2026-05-22
4354	1253	8	12	12	48.81	2026-05-22
4355	1253	11	18	5	191.14	2026-05-22
4356	1254	13	36	36	97.54	2026-05-22
4357	1254	8	18	18	49.81	2026-05-22
4358	1255	7	6	6	159.96	2026-05-22
4359	1255	37	48	48	129.57	2026-05-22
4360	1255	21	72	72	59.84	2026-05-22
4361	1256	26	18	0	55.53	\N
4362	1256	9	72	72	129.89	2026-05-23
4363	1257	13	36	36	92.66	2026-05-22
4364	1257	31	24	24	142.92	2026-05-22
4365	1257	6	72	0	146.84	\N
4366	1257	5	72	72	105.48	2026-05-22
4367	1257	36	48	48	113.56	2026-05-22
4368	1258	35	36	36	125.1	2026-05-23
4369	1258	12	72	72	145.58	2026-05-23
4370	1258	6	72	72	154.57	2026-05-23
4371	1258	31	72	72	150.44	2026-05-23
4372	1259	34	12	12	134.91	2026-05-24
4373	1259	18	48	0	82.83	\N
4374	1260	12	72	72	138.3	2026-05-23
4375	1260	19	48	48	145.9	2026-05-23
4376	1261	29	12	12	47.33	2026-05-23
4377	1261	28	36	36	176.24	2026-05-23
4378	1261	4	12	12	37.77	2026-05-23
4379	1261	31	72	72	150.44	2026-05-23
4380	1262	12	72	72	138.3	2026-05-23
4381	1262	2	6	6	99.11	2026-05-23
4382	1262	37	72	72	123.09	2026-05-23
4383	1263	2	6	6	104.33	2026-05-25
4384	1263	6	24	24	154.57	2026-05-25
4385	1263	12	24	24	145.58	2026-05-25
4386	1264	11	18	18	195.04	2026-05-24
4387	1264	12	48	48	145.58	2026-05-24
4388	1264	14	24	0	116.19	\N
4389	1265	25	12	12	171.1	2026-05-26
4390	1265	27	24	24	17.24	2026-05-26
4391	1265	5	72	72	111.03	2026-05-26
4392	1265	6	48	48	154.57	2026-05-26
4393	1266	4	12	12	37.01	2026-05-26
4394	1266	33	6	6	114.93	2026-05-26
4395	1266	31	24	11	147.43	2026-05-26
4396	1266	9	24	24	127.29	2026-05-26
4397	1267	4	24	24	37.01	2026-05-26
4398	1267	5	48	48	108.81	2026-05-26
4399	1267	3	36	36	26.21	2026-05-26
4400	1268	1	12	12	12.24	2026-05-25
4401	1268	37	72	72	126.98	2026-05-25
4402	1268	12	48	48	142.67	2026-05-25
4403	1269	4	12	12	37.77	2026-05-25
4404	1269	8	18	18	49.81	2026-05-25
4405	1269	33	18	18	117.28	2026-05-25
4406	1270	24	24	24	36.72	2026-05-26
4407	1270	2	6	6	104.33	2026-05-26
4408	1270	6	24	24	154.57	2026-05-26
4409	1270	18	24	24	82.83	2026-05-26
4410	1271	24	72	72	34.88	2026-05-25
4411	1271	28	24	0	167.43	\N
4412	1271	26	12	0	52.75	\N
4413	1272	36	72	72	113.56	2026-05-25
4414	1272	3	24	24	25.4	2026-05-25
4415	1272	5	24	24	105.48	2026-05-25
4416	1272	39	18	18	30.89	2026-05-25
4417	1273	37	48	48	129.57	2026-05-25
4418	1273	15	36	36	170.21	2026-05-25
4419	1274	24	24	24	34.88	2026-05-25
4420	1274	9	24	24	123.4	2026-05-25
4421	1275	13	12	12	97.54	2026-05-26
4422	1275	33	6	6	117.28	2026-05-26
4423	1275	24	72	72	36.72	2026-05-26
4424	1275	2	12	12	104.33	2026-05-26
4425	1276	22	6	6	165.43	2026-05-26
4426	1276	5	24	24	111.03	2026-05-26
4427	1276	15	36	36	170.21	2026-05-26
4428	1276	25	18	6	171.1	2026-05-26
4429	1277	40	18	18	36.74	2026-05-26
4430	1277	27	24	0	16.38	\N
4431	1277	33	18	18	111.42	2026-05-26
4432	1277	38	12	12	147.67	2026-05-26
4433	1278	37	24	24	129.57	2026-05-26
4434	1278	12	72	72	145.58	2026-05-26
4435	1278	38	12	12	155.44	2026-05-26
4436	1278	16	36	36	161.56	2026-05-26
4437	1278	2	12	12	104.33	2026-05-26
4438	1279	37	48	48	123.09	2026-05-26
4439	1279	17	12	12	50.36	2026-05-26
4440	1280	3	24	24	26.74	2026-05-27
4441	1280	1	12	12	12.49	2026-05-27
4442	1280	9	24	24	129.89	2026-05-27
4443	1280	8	6	6	49.81	2026-05-27
4444	1281	38	24	24	155.44	2026-05-27
4445	1281	15	12	12	170.21	2026-05-27
4446	1281	1	6	6	12.49	2026-05-27
4447	1281	39	18	18	32.52	2026-05-27
4448	1281	25	18	18	171.1	2026-05-27
4449	1282	9	24	24	129.89	2026-05-27
4450	1282	22	18	18	165.43	2026-05-27
4451	1282	3	24	24	26.74	2026-05-27
4452	1282	29	12	12	47.33	2026-05-27
4453	1282	4	12	12	37.77	2026-05-27
4454	1283	4	24	24	37.77	2026-05-27
4455	1283	12	48	48	145.58	2026-05-27
4456	1283	37	48	48	129.57	2026-05-27
4457	1284	3	24	24	26.74	2026-05-27
4458	1284	35	24	24	125.1	2026-05-27
4459	1284	33	18	18	117.28	2026-05-27
4460	1285	40	6	6	38.67	2026-05-27
4461	1285	11	18	18	195.04	2026-05-27
4462	1285	3	12	12	26.74	2026-05-27
4463	1285	25	18	18	171.1	2026-05-27
4464	1286	39	18	18	32.52	2026-05-29
4465	1286	4	36	36	37.77	2026-05-29
4466	1286	5	72	72	111.03	2026-05-29
4467	1287	6	24	24	146.84	2026-05-28
4468	1287	31	24	0	142.92	\N
4469	1288	37	48	48	129.57	2026-05-28
4470	1288	16	36	36	161.56	2026-05-28
4471	1289	37	72	72	129.57	2026-05-29
4472	1289	20	12	12	68.61	2026-05-29
4473	1289	1	6	6	12.49	2026-05-29
4474	1289	29	6	6	47.33	2026-05-29
4475	1290	4	36	36	35.88	2026-05-29
4476	1290	9	72	72	123.4	2026-05-29
4477	1290	31	24	0	142.92	\N
4478	1291	24	48	48	36.72	2026-05-29
4479	1291	6	72	72	154.57	2026-05-29
4480	1291	38	12	12	155.44	2026-05-29
4481	1291	5	24	24	111.03	2026-05-29
4482	1292	3	24	24	25.4	2026-05-30
4483	1292	29	6	5	44.96	2026-05-30
4484	1293	1	6	6	11.87	2026-05-29
4485	1293	12	48	48	138.3	2026-05-29
4486	1293	16	12	12	153.48	2026-05-29
4487	1293	31	72	72	142.92	2026-05-29
4488	1294	9	72	64	123.4	2026-05-30
4489	1294	38	36	36	147.67	2026-05-30
4490	1294	1	6	6	11.87	2026-05-30
4491	1295	8	12	12	48.81	2026-05-30
4492	1295	25	6	6	167.68	2026-05-30
4493	1296	34	36	36	132.21	2026-05-29
4494	1296	24	24	24	35.99	2026-05-29
4495	1297	2	12	12	104.33	2026-05-29
4496	1297	4	36	36	37.77	2026-05-29
4497	1297	1	12	12	12.49	2026-05-29
4498	1298	37	48	48	129.57	2026-05-30
4499	1298	6	24	24	154.57	2026-05-30
4500	1299	31	24	0	147.43	\N
4501	1299	38	12	12	152.33	2026-05-30
4502	1299	30	48	48	180.6	2026-05-30
4503	1299	32	18	18	121.7	2026-05-30
4504	1299	1	6	6	12.24	2026-05-30
4505	1300	25	12	0	162.54	\N
4506	1300	5	24	24	105.48	2026-05-31
4507	1300	10	48	48	71.16	2026-05-31
4508	1300	4	36	36	35.88	2026-05-31
4509	1300	1	18	18	11.87	2026-05-31
4510	1301	31	48	48	142.92	2026-05-31
4511	1301	2	18	18	99.11	2026-05-31
4512	1301	9	48	0	123.4	\N
4513	1301	5	48	48	105.48	2026-05-31
4514	1302	2	18	18	104.33	2026-06-01
4515	1302	31	48	0	150.44	\N
4516	1302	1	6	6	12.49	2026-06-01
4517	1303	20	6	6	68.61	2026-06-01
4518	1303	13	36	36	97.54	2026-06-01
4519	1303	17	12	12	53.01	2026-06-01
4520	1304	35	12	12	125.1	2026-06-02
4521	1304	10	48	0	74.91	\N
4522	1304	5	48	0	111.03	\N
4523	1304	30	72	72	184.29	2026-06-02
4524	1304	37	72	72	129.57	2026-06-02
4525	1305	14	12	12	113.87	2026-06-01
4526	1305	1	6	6	12.24	2026-06-01
4527	1305	12	48	48	142.67	2026-06-01
4528	1306	24	48	48	36.72	2026-06-01
4529	1306	38	12	12	155.44	2026-06-01
4530	1307	39	6	6	31.87	2026-06-01
4531	1307	1	6	6	12.24	2026-06-01
4532	1307	33	18	18	114.93	2026-06-01
4533	1307	31	48	48	147.43	2026-06-01
4534	1307	2	6	6	102.24	2026-06-01
4535	1308	6	24	0	146.84	\N
4536	1308	24	72	72	34.88	2026-06-01
4537	1308	31	48	48	142.92	2026-06-01
4538	1308	2	18	18	99.11	2026-06-01
4539	1309	37	72	72	123.09	2026-06-02
4540	1309	2	12	12	99.11	2026-06-02
4541	1309	8	12	12	47.32	2026-06-02
4542	1309	11	12	12	185.29	2026-06-02
4543	1310	2	18	18	104.33	2026-06-02
4544	1310	39	6	6	32.52	2026-06-02
4545	1310	1	12	12	12.49	2026-06-02
4546	1310	4	36	36	37.77	2026-06-02
4547	1310	17	6	6	53.01	2026-06-02
4548	1311	21	48	48	59.84	2026-06-02
4549	1311	14	36	36	116.19	2026-06-02
4550	1312	37	72	72	129.57	2026-06-02
4551	1312	1	6	6	12.49	2026-06-02
4552	1312	5	24	24	111.03	2026-06-02
4553	1313	31	48	48	150.44	2026-06-02
4554	1313	12	48	48	145.58	2026-06-02
4555	1313	36	48	48	119.54	2026-06-02
4556	1313	33	18	18	117.28	2026-06-02
4557	1314	31	72	72	142.92	2026-06-03
4558	1314	19	72	72	145.9	2026-06-03
4559	1315	5	72	72	105.48	2026-06-03
4560	1315	8	12	12	47.32	2026-06-03
4561	1315	9	48	48	123.4	2026-06-03
4562	1315	39	6	6	30.89	2026-06-03
4563	1315	1	18	0	11.87	\N
4564	1316	2	18	18	104.33	2026-06-04
4565	1316	26	18	18	55.53	2026-06-04
4566	1317	34	12	12	132.21	2026-06-03
4567	1317	5	24	24	108.81	2026-06-03
4568	1318	35	12	12	118.84	2026-06-03
4569	1318	5	24	24	105.48	2026-06-03
4570	1318	27	36	0	16.38	\N
4571	1318	16	12	12	153.48	2026-06-03
4572	1318	12	24	24	138.3	2026-06-03
4573	1319	23	24	24	44.56	2026-06-04
4574	1319	37	48	48	123.09	2026-06-04
4575	1320	5	24	24	111.03	2026-06-03
4576	1320	6	72	72	154.57	2026-06-03
4577	1320	13	24	24	97.54	2026-06-03
4578	1321	5	24	24	108.81	2026-06-04
4579	1321	26	18	0	54.42	\N
4580	1321	32	6	6	121.7	2026-06-04
4581	1321	31	48	48	147.43	2026-06-04
4582	1322	4	36	36	37.77	2026-06-03
4583	1322	24	24	24	36.72	2026-06-03
4584	1322	38	12	12	155.44	2026-06-03
4585	1323	16	36	36	161.56	2026-06-03
4586	1323	27	24	24	17.24	2026-06-03
4587	1324	26	12	12	55.53	2026-06-03
4588	1324	24	72	39	36.72	2026-06-03
4589	1325	5	48	48	108.81	2026-06-03
4590	1325	21	72	72	58.64	2026-06-03
4591	1325	6	24	24	151.48	2026-06-03
4592	1325	2	6	6	102.24	2026-06-03
4593	1325	33	6	6	114.93	2026-06-03
4594	1326	4	12	12	37.77	2026-06-05
4595	1326	37	24	24	129.57	2026-06-05
4596	1326	21	24	24	59.84	2026-06-05
4597	1326	16	12	12	161.56	2026-06-05
4598	1327	12	24	24	138.3	2026-06-04
4599	1327	4	36	36	35.88	2026-06-04
4600	1327	1	6	6	11.87	2026-06-04
4601	1327	3	24	24	25.4	2026-06-04
4602	1328	18	48	48	82.83	2026-06-04
4603	1328	6	24	24	154.57	2026-06-04
4604	1328	5	72	72	111.03	2026-06-04
4605	1328	37	48	48	129.57	2026-06-04
4606	1329	2	18	4	104.33	2026-06-04
4607	1329	4	36	36	37.77	2026-06-04
4608	1329	13	24	24	97.54	2026-06-04
4609	1329	26	6	0	55.53	\N
4610	1329	37	72	72	129.57	2026-06-04
4611	1330	1	18	18	12.49	2026-06-05
4612	1330	10	48	48	74.91	2026-06-05
4613	1330	31	72	72	150.44	2026-06-05
4614	1331	12	72	72	142.67	2026-06-05
4615	1331	18	48	48	81.17	2026-06-05
4616	1331	5	72	72	108.81	2026-06-05
4617	1332	3	12	12	26.74	2026-06-05
4618	1332	36	48	48	119.54	2026-06-05
4619	1332	20	18	18	68.61	2026-06-05
4620	1332	7	18	18	159.96	2026-06-05
4621	1333	30	72	72	180.6	2026-06-05
4622	1333	12	24	24	142.67	2026-06-05
4623	1333	25	12	12	167.68	2026-06-05
4624	1334	4	36	36	37.77	2026-06-05
4625	1334	2	12	12	104.33	2026-06-05
4626	1334	20	6	6	68.61	2026-06-05
4627	1334	11	18	18	195.04	2026-06-05
4628	1335	3	12	12	26.21	2026-06-06
4629	1335	11	6	6	191.14	2026-06-06
4630	1335	13	24	24	95.59	2026-06-06
4631	1335	30	24	0	180.6	\N
4632	1335	9	24	0	127.29	\N
4633	1336	2	6	6	104.33	2026-06-05
4634	1336	38	12	12	155.44	2026-06-05
4635	1336	37	24	24	129.57	2026-06-05
4636	1336	10	48	48	74.91	2026-06-05
4637	1336	3	12	12	26.74	2026-06-05
4638	1337	15	12	12	170.21	2026-06-05
4639	1337	7	12	12	159.96	2026-06-05
4640	1338	13	36	36	95.59	2026-06-05
4641	1338	6	72	72	151.48	2026-06-05
4642	1338	16	36	36	158.33	2026-06-05
4643	1339	20	6	6	67.24	2026-06-06
4644	1339	29	6	0	46.38	\N
4645	1339	26	18	0	54.42	\N
4646	1339	25	12	12	167.68	2026-06-06
4647	1339	9	48	0	127.29	\N
4648	1340	2	18	18	99.11	2026-06-06
4649	1340	22	12	12	157.16	2026-06-06
4650	1340	31	48	48	142.92	2026-06-06
4651	1341	5	72	72	111.03	2026-06-06
4652	1341	12	24	24	145.58	2026-06-06
4653	1341	24	72	0	36.72	\N
4654	1341	13	12	12	97.54	2026-06-06
4655	1342	1	18	18	12.49	2026-06-07
4656	1342	14	24	24	116.19	2026-06-07
4657	1342	4	12	12	37.77	2026-06-07
4658	1343	27	12	0	16.9	\N
4659	1343	29	12	12	46.38	2026-06-08
4660	1343	10	72	0	73.41	\N
4661	1343	16	24	24	158.33	2026-06-08
4662	1344	8	12	12	49.81	2026-06-08
4663	1344	26	6	0	55.53	\N
4664	1344	31	24	24	150.44	2026-06-08
4665	1345	8	6	2	49.81	2026-06-07
4666	1345	21	72	72	59.84	2026-06-07
4667	1345	38	24	24	155.44	2026-06-07
4668	1346	2	6	6	104.33	2026-06-07
4669	1346	35	36	36	125.1	2026-06-07
4670	1346	25	18	18	171.1	2026-06-07
4671	1347	5	72	72	111.03	2026-06-07
4672	1347	6	24	24	154.57	2026-06-07
4673	1347	12	48	48	145.58	2026-06-07
4674	1348	17	12	12	53.01	2026-06-07
4675	1348	12	48	48	145.58	2026-06-07
4676	1348	4	12	12	37.77	2026-06-07
4677	1349	19	24	24	153.58	2026-06-08
4678	1349	38	36	36	155.44	2026-06-08
4679	1349	2	6	6	104.33	2026-06-08
4680	1349	6	48	48	154.57	2026-06-08
4681	1349	3	36	36	26.74	2026-06-08
4682	1350	39	12	12	30.89	2026-06-08
4683	1350	31	48	48	142.92	2026-06-08
4684	1350	4	24	24	35.88	2026-06-08
4685	1351	2	18	18	102.24	2026-06-09
4686	1351	3	36	36	26.21	2026-06-09
4687	1351	25	12	12	167.68	2026-06-09
4688	1352	3	12	12	26.74	2026-06-08
4689	1352	38	36	36	155.44	2026-06-08
4690	1353	12	48	48	138.3	2026-06-09
4691	1353	2	6	6	99.11	2026-06-09
4692	1353	4	36	36	35.88	2026-06-09
4693	1353	34	12	12	128.16	2026-06-09
4694	1354	1	18	18	12.24	2026-06-08
4695	1354	2	6	6	102.24	2026-06-08
4696	1355	17	12	12	51.95	2026-06-08
4697	1355	31	24	24	147.43	2026-06-08
4698	1355	37	48	48	126.98	2026-06-08
4699	1355	3	12	12	26.21	2026-06-08
4700	1355	29	12	0	46.38	\N
4701	1356	20	6	6	68.61	2026-06-08
4702	1356	16	24	24	161.56	2026-06-08
4703	1356	6	24	24	154.57	2026-06-08
4704	1356	3	36	36	26.74	2026-06-08
4705	1357	3	12	0	25.4	\N
4706	1357	38	24	24	147.67	2026-06-08
4707	1357	33	18	18	111.42	2026-06-08
4708	1357	24	24	24	34.88	2026-06-08
4709	1358	4	12	12	37.77	2026-06-08
4710	1358	31	24	24	150.44	2026-06-08
4711	1359	33	6	6	117.28	2026-06-09
4712	1359	21	48	48	59.84	2026-06-09
4713	1359	2	12	12	104.33	2026-06-09
4714	1360	3	24	24	26.74	2026-06-10
4715	1360	4	36	36	37.77	2026-06-10
4716	1360	39	12	12	32.52	2026-06-10
4717	1361	4	36	31	37.77	2026-06-09
4718	1361	8	12	0	49.81	\N
4719	1361	9	48	48	129.89	2026-06-09
4720	1362	40	6	6	38.67	2026-06-09
4721	1362	5	24	24	111.03	2026-06-09
4722	1362	4	24	0	37.77	\N
4723	1363	6	24	24	151.48	2026-06-09
4724	1363	12	24	24	142.67	2026-06-09
4725	1363	2	6	6	102.24	2026-06-09
4726	1363	1	12	12	12.24	2026-06-09
4727	1364	2	12	12	99.11	2026-06-09
4728	1364	15	24	24	161.7	2026-06-09
4729	1365	37	48	48	129.57	2026-06-09
4730	1365	1	18	18	12.49	2026-06-09
4731	1365	13	24	24	97.54	2026-06-09
4732	1365	9	72	72	129.89	2026-06-09
4733	1365	31	48	48	150.44	2026-06-09
4734	1366	39	12	12	30.89	2026-06-10
4735	1366	19	48	48	145.9	2026-06-10
4736	1366	23	24	24	44.56	2026-06-10
4737	1366	31	72	72	142.92	2026-06-10
4738	1367	12	24	24	145.58	2026-06-11
4739	1367	10	24	0	74.91	\N
4740	1367	1	18	18	12.49	2026-06-11
4741	1367	37	24	24	129.57	2026-06-11
4742	1368	2	18	18	104.33	2026-06-10
4743	1368	13	36	36	97.54	2026-06-10
4744	1368	12	48	48	145.58	2026-06-10
4745	1368	32	6	6	124.18	2026-06-10
4746	1369	7	12	12	159.96	2026-06-10
4747	1369	12	72	72	145.58	2026-06-10
4748	1370	5	24	24	111.03	2026-06-10
4749	1370	39	18	18	32.52	2026-06-10
4750	1371	5	24	24	105.48	2026-06-11
4751	1371	29	12	0	44.96	\N
4752	1371	38	36	36	147.67	2026-06-11
4753	1371	4	12	0	35.88	\N
4754	1371	8	18	0	47.32	\N
4755	1372	31	72	72	150.44	2026-06-11
4756	1372	4	36	36	37.77	2026-06-11
4757	1372	15	36	36	170.21	2026-06-11
4758	1373	3	24	24	26.74	2026-06-10
4759	1373	24	24	24	36.72	2026-06-10
4760	1374	16	24	24	161.56	2026-06-11
4761	1374	9	24	24	129.89	2026-06-11
4762	1374	12	72	72	145.58	2026-06-11
4763	1375	9	48	48	127.29	2026-06-11
4764	1375	16	12	12	158.33	2026-06-11
4765	1376	5	72	72	108.81	2026-06-11
4766	1376	4	12	12	37.01	2026-06-11
4767	1376	38	36	36	152.33	2026-06-11
4768	1376	14	12	12	113.87	2026-06-11
4769	1376	27	12	0	16.9	\N
4770	1377	16	12	12	161.56	2026-06-11
4771	1377	12	24	24	145.58	2026-06-11
4772	1377	33	6	6	117.28	2026-06-11
4773	1378	9	24	24	127.29	2026-06-11
4774	1378	29	12	0	46.38	\N
4775	1378	20	12	12	67.24	2026-06-11
4776	1379	28	36	36	176.24	2026-06-11
4777	1379	32	18	18	124.18	2026-06-11
4778	1379	2	12	12	104.33	2026-06-11
4779	1380	27	12	12	16.9	2026-06-12
4780	1380	31	24	24	147.43	2026-06-12
4781	1380	5	24	24	108.81	2026-06-12
4782	1380	2	18	18	102.24	2026-06-12
4783	1381	12	72	72	145.58	2026-06-11
4784	1381	13	24	24	97.54	2026-06-11
4785	1381	35	12	12	125.1	2026-06-11
4786	1381	33	12	12	117.28	2026-06-11
4787	1382	12	24	24	138.3	2026-06-12
4788	1382	17	6	6	50.36	2026-06-12
4789	1382	3	24	24	25.4	2026-06-12
4790	1382	39	12	12	30.89	2026-06-12
4791	1383	33	18	18	114.93	2026-06-11
4792	1383	2	12	12	102.24	2026-06-11
4793	1383	31	24	24	147.43	2026-06-11
4794	1383	4	24	24	37.01	2026-06-11
4795	1384	3	36	24	26.74	2026-06-12
4796	1384	30	72	72	184.29	2026-06-12
4797	1385	26	12	12	52.75	2026-06-12
4798	1385	3	12	0	25.4	\N
4799	1386	38	12	12	155.44	2026-06-12
4800	1386	9	24	24	129.89	2026-06-12
4801	1386	30	24	24	184.29	2026-06-12
4802	1386	11	12	12	195.04	2026-06-12
4803	1386	6	24	9	154.57	2026-06-12
4804	1387	31	72	72	150.44	2026-06-12
4805	1387	40	6	6	38.67	2026-06-12
4806	1388	28	36	36	176.24	2026-06-12
4807	1388	9	72	24	129.89	2026-06-12
4808	1388	31	72	72	150.44	2026-06-12
4809	1388	1	6	6	12.49	2026-06-12
4810	1388	26	12	12	55.53	2026-06-12
4811	1389	38	12	12	147.67	2026-06-13
4812	1389	13	24	24	92.66	2026-06-13
4813	1389	29	6	6	44.96	2026-06-13
4814	1389	31	48	48	142.92	2026-06-13
4815	1390	4	24	0	35.88	\N
4816	1390	2	6	6	99.11	2026-06-12
4817	1390	31	48	48	142.92	2026-06-12
4818	1391	5	48	48	111.03	2026-06-12
4819	1391	26	18	18	55.53	2026-06-12
4820	1391	14	36	36	116.19	2026-06-12
4821	1391	4	12	0	37.77	\N
4822	1392	5	72	72	111.03	2026-06-12
4823	1392	17	18	18	53.01	2026-06-12
4824	1392	23	12	12	46.91	2026-06-12
4825	1392	37	48	48	129.57	2026-06-12
4826	1392	26	12	12	55.53	2026-06-12
4827	1393	3	12	12	26.21	2026-06-12
4828	1393	31	72	72	147.43	2026-06-12
4829	1393	5	24	24	108.81	2026-06-12
4830	1393	34	12	12	132.21	2026-06-12
4831	1393	2	12	12	102.24	2026-06-12
4832	1394	24	24	24	36.72	2026-06-12
4833	1394	2	12	12	104.33	2026-06-12
4834	1395	17	6	6	50.36	2026-06-12
4835	1395	2	18	18	99.11	2026-06-12
4836	1395	11	6	6	185.29	2026-06-12
4837	1395	37	24	24	123.09	2026-06-12
4838	1396	2	12	6	104.33	2026-06-13
4839	1396	15	36	36	170.21	2026-06-13
4840	1397	3	12	12	26.21	2026-06-12
4841	1397	5	24	24	108.81	2026-06-12
4842	1397	2	6	0	102.24	\N
4843	1397	16	24	24	158.33	2026-06-12
4844	1397	21	72	72	58.64	2026-06-12
4845	1398	25	18	18	162.54	2026-06-14
4846	1398	1	6	6	11.87	2026-06-14
4847	1398	4	12	12	35.88	2026-06-14
4848	1398	11	6	6	185.29	2026-06-14
4849	1399	1	6	6	11.87	2026-06-14
4850	1399	4	24	24	35.88	2026-06-14
4851	1399	31	24	24	142.92	2026-06-14
4852	1399	28	36	36	167.43	2026-06-14
4853	1400	38	36	36	147.67	2026-06-13
4854	1400	5	48	48	105.48	2026-06-13
4855	1400	16	24	24	153.48	2026-06-13
4856	1401	8	18	18	49.81	2026-06-14
4857	1401	31	48	48	150.44	2026-06-14
4858	1401	39	18	18	32.52	2026-06-14
4859	1402	25	18	18	167.68	2026-06-15
4860	1402	31	24	24	147.43	2026-06-15
4861	1402	33	6	6	114.93	2026-06-15
4862	1402	39	12	12	31.87	2026-06-15
4863	1402	8	12	12	48.81	2026-06-15
4864	1403	30	72	0	175.08	\N
4865	1403	2	6	6	99.11	2026-06-14
4866	1403	4	12	12	35.88	2026-06-14
4867	1404	5	48	48	111.03	2026-06-15
4868	1404	4	36	36	37.77	2026-06-15
4869	1404	2	12	6	104.33	2026-06-15
4870	1405	6	24	24	154.57	2026-06-14
4871	1405	37	72	72	129.57	2026-06-14
4872	1406	2	18	0	99.11	\N
4873	1406	12	48	48	138.3	2026-06-14
4874	1406	40	6	6	36.74	2026-06-14
4875	1406	13	12	12	92.66	2026-06-14
4876	1407	6	24	0	146.84	\N
4877	1407	37	48	48	123.09	2026-06-15
4878	1407	9	48	0	123.4	\N
4879	1407	38	36	36	147.67	2026-06-15
4880	1408	1	6	6	12.49	2026-06-15
4881	1408	6	24	24	154.57	2026-06-15
4882	1408	9	24	24	129.89	2026-06-15
4883	1409	3	12	12	26.74	2026-06-15
4884	1409	5	48	24	111.03	2026-06-15
4885	1409	19	72	72	153.58	2026-06-15
4886	1410	2	12	12	99.11	2026-06-16
4887	1410	12	24	24	138.3	2026-06-16
4888	1410	32	6	6	117.97	2026-06-16
4889	1411	16	12	12	161.56	2026-06-17
4890	1411	20	6	6	68.61	2026-06-17
4891	1411	30	24	24	184.29	2026-06-17
4892	1412	31	24	24	142.92	2026-06-19
4893	1412	37	48	48	123.09	2026-06-19
4894	1412	39	6	6	30.89	2026-06-19
4895	1413	33	6	6	111.42	2026-06-21
4896	1413	37	24	24	123.09	2026-06-21
4897	1414	16	12	12	153.48	2026-06-21
4898	1414	35	12	12	118.84	2026-06-21
4899	1414	38	36	36	147.67	2026-06-21
4900	1414	22	18	18	157.16	2026-06-21
4901	1415	5	48	48	108.81	2026-06-19
4902	1415	2	6	0	102.24	\N
4903	1416	4	36	36	37.77	2026-06-20
4904	1416	23	24	24	46.91	2026-06-20
4905	1416	16	12	12	161.56	2026-06-20
4906	1417	6	48	48	154.57	2026-06-22
4907	1417	29	18	0	47.33	\N
4908	1417	39	18	18	32.52	2026-06-22
4909	1418	5	48	0	111.03	\N
4910	1418	10	24	24	74.91	2026-06-16
4911	1418	6	24	24	154.57	2026-06-16
4912	1419	38	24	24	155.44	2026-06-16
4913	1419	2	6	0	104.33	\N
4914	1419	32	12	12	124.18	2026-06-16
4915	1419	5	48	0	111.03	\N
4916	1420	21	48	0	59.84	\N
4917	1420	39	12	12	32.52	2026-06-16
4918	1420	5	72	0	111.03	\N
4919	1420	13	24	24	97.54	2026-06-16
4920	1420	4	36	36	37.77	2026-06-16
4921	1421	6	72	0	146.84	\N
4922	1421	31	24	24	142.92	2026-06-17
4923	1421	32	18	18	117.97	2026-06-17
4924	1421	2	12	12	99.11	2026-06-17
4925	1421	24	72	72	34.88	2026-06-17
4926	1422	16	12	12	153.48	2026-06-18
4927	1422	31	48	48	142.92	2026-06-18
4928	1422	10	72	72	71.16	2026-06-18
4929	1422	9	48	0	123.4	\N
4930	1423	9	48	48	129.89	2026-06-22
4931	1423	30	72	0	184.29	\N
4932	1423	1	12	12	12.49	2026-06-22
4933	1424	5	72	24	111.03	2026-06-22
4934	1424	39	18	18	32.52	2026-06-22
4935	1424	12	24	24	145.58	2026-06-22
4936	1425	1	6	6	12.49	2026-06-17
4937	1425	4	36	36	37.77	2026-06-17
4938	1425	5	48	0	111.03	\N
4939	1426	9	24	24	123.4	2026-06-18
4940	1426	7	6	6	151.96	2026-06-18
4941	1427	24	48	48	36.72	2026-06-17
4942	1427	37	24	24	129.57	2026-06-17
4943	1427	13	36	36	97.54	2026-06-17
4944	1427	38	24	24	155.44	2026-06-17
4945	1427	4	12	12	37.77	2026-06-17
4946	1428	37	72	72	129.57	2026-06-17
4947	1428	33	6	6	117.28	2026-06-17
4948	1429	12	24	24	138.3	2026-06-18
4949	1429	10	24	24	71.16	2026-06-18
4950	1429	2	12	12	99.11	2026-06-18
4951	1429	16	36	5	153.48	2026-06-18
4952	1429	3	24	0	25.4	\N
4953	1430	31	48	48	150.44	2026-06-18
4954	1430	4	36	36	37.77	2026-06-18
4955	1430	27	36	0	17.24	\N
4956	1430	5	24	24	111.03	2026-06-18
4957	1430	3	36	0	26.74	\N
4958	1431	9	72	0	129.89	\N
4959	1431	23	36	36	46.91	2026-06-18
4960	1431	2	12	12	104.33	2026-06-18
4961	1432	31	48	48	147.43	2026-06-18
4962	1432	3	12	0	26.21	\N
4963	1432	2	6	6	102.24	2026-06-18
4964	1433	5	48	48	111.03	2026-06-18
4965	1433	4	24	24	37.77	2026-06-18
4966	1433	15	36	36	170.21	2026-06-18
4967	1433	9	72	0	129.89	\N
4968	1433	29	6	6	47.33	2026-06-18
4969	1434	9	48	0	129.89	\N
4970	1434	36	72	72	119.54	2026-06-18
4971	1435	5	24	0	111.03	\N
4972	1435	27	24	24	17.24	2026-06-22
4973	1435	23	12	12	46.91	2026-06-22
4974	1436	2	6	0	102.24	\N
4975	1436	11	12	12	191.14	2026-06-22
4976	1436	14	36	36	113.87	2026-06-22
4977	1436	4	36	36	37.01	2026-06-22
4978	1437	33	18	18	111.42	2026-06-18
4979	1437	3	12	12	25.4	2026-06-18
4980	1437	5	48	0	105.48	\N
4981	1437	12	24	24	138.3	2026-06-18
4982	1438	2	12	0	99.11	\N
4983	1438	33	6	6	111.42	2026-06-18
4984	1438	16	24	24	153.48	2026-06-18
4985	1438	3	36	0	25.4	\N
4986	1438	12	72	72	138.3	2026-06-18
4987	1439	5	48	0	111.03	\N
4988	1439	4	24	24	37.77	2026-06-18
4989	1439	6	48	48	154.57	2026-06-18
4990	1439	37	24	24	129.57	2026-06-18
4991	1439	24	72	72	36.72	2026-06-18
4992	1440	25	12	12	171.1	2026-06-19
4993	1440	34	36	36	134.91	2026-06-19
4994	1440	5	24	0	111.03	\N
4995	1441	5	48	0	105.48	\N
4996	1441	1	6	6	11.87	2026-06-18
4997	1442	12	24	24	145.58	2026-06-18
4998	1442	5	24	0	111.03	\N
4999	1442	35	24	24	125.1	2026-06-18
5000	1442	4	24	24	37.77	2026-06-18
5001	1443	26	12	12	55.53	2026-06-19
5002	1443	16	24	0	161.56	\N
5003	1443	21	72	72	59.84	2026-06-19
5004	1443	3	12	0	26.74	\N
5005	1444	15	36	36	170.21	2026-06-22
5006	1444	30	72	0	184.29	\N
5007	1444	2	12	0	104.33	\N
5008	1445	6	48	48	154.57	2026-06-24
5009	1445	23	24	24	46.91	2026-06-24
5010	1445	29	18	0	47.33	\N
5011	1445	38	12	12	155.44	2026-06-24
5012	1445	30	72	0	184.29	\N
5013	1446	22	18	18	165.43	2026-06-19
5014	1446	31	72	72	150.44	2026-06-19
5015	1447	15	24	24	161.7	2026-06-21
5016	1447	39	12	12	30.89	2026-06-21
5017	1447	21	24	24	56.85	2026-06-21
5018	1447	35	12	12	118.84	2026-06-21
5019	1447	5	72	72	105.48	2026-06-21
5020	1448	7	18	18	159.96	2026-06-25
5021	1448	37	48	48	129.57	2026-06-25
5022	1448	23	12	12	46.91	2026-06-25
5023	1449	5	48	48	105.48	2026-06-21
5024	1449	13	36	36	92.66	2026-06-21
5025	1449	26	12	12	52.75	2026-06-21
5026	1449	12	72	72	138.3	2026-06-21
5027	1449	37	24	24	123.09	2026-06-21
5028	1450	16	24	0	158.33	\N
5029	1450	39	6	6	31.87	2026-06-22
5030	1450	34	36	36	132.21	2026-06-22
5031	1450	13	24	24	95.59	2026-06-22
5032	1450	40	6	6	37.9	2026-06-22
5033	1451	26	18	18	55.53	2026-06-23
5034	1451	5	24	24	111.03	2026-06-23
5035	1451	6	72	0	154.57	\N
5036	1452	16	12	12	161.56	2026-06-27
5037	1452	31	48	48	150.44	2026-06-27
5038	1453	6	24	24	154.57	2026-06-28
5039	1453	4	24	24	37.77	2026-06-28
5040	1453	9	72	72	129.89	2026-06-28
5041	1453	37	24	24	129.57	2026-06-28
5042	1454	12	24	24	138.3	2026-06-27
5043	1454	6	72	71	146.84	2026-06-27
5044	1455	12	48	48	145.58	2026-06-25
5045	1455	34	12	12	134.91	2026-06-25
5046	1455	39	12	12	32.52	2026-06-25
5047	1455	4	24	24	37.77	2026-06-25
5048	1455	2	12	0	104.33	\N
5049	1456	16	36	36	153.48	2026-06-23
5050	1456	39	18	18	30.89	2026-06-23
5051	1456	2	12	0	99.11	\N
5052	1456	32	12	12	117.97	2026-06-23
5053	1456	5	24	24	105.48	2026-06-23
5054	1457	33	6	6	117.28	2026-06-22
5055	1457	28	24	24	176.24	2026-06-22
5056	1458	7	18	18	151.96	2026-06-23
5057	1458	39	12	12	30.89	2026-06-23
5058	1459	8	12	12	49.81	2026-06-23
5059	1459	22	18	18	165.43	2026-06-23
5060	1459	2	6	0	104.33	\N
5061	1459	31	48	48	150.44	2026-06-23
5062	1459	24	72	72	36.72	2026-06-23
5063	1460	15	36	36	170.21	2026-06-24
5064	1460	27	24	0	17.24	\N
5065	1460	2	12	12	104.33	2026-06-24
5066	1461	31	72	72	142.92	2026-06-24
5067	1461	39	12	12	30.89	2026-06-24
5068	1461	4	36	36	35.88	2026-06-24
5069	1461	7	18	18	151.96	2026-06-24
5070	1461	12	48	48	138.3	2026-06-24
5071	1462	5	48	0	108.81	\N
5072	1462	7	6	6	156.76	2026-06-29
5073	1462	31	24	24	147.43	2026-06-29
5074	1462	39	12	12	31.87	2026-06-29
5075	1462	37	48	48	126.98	2026-06-29
5076	1463	31	72	72	150.44	2026-06-29
5077	1463	37	72	72	129.57	2026-06-29
5078	1463	5	48	0	111.03	\N
5079	1464	1	12	12	12.24	2026-06-24
5080	1464	28	36	36	172.72	2026-06-24
5081	1464	3	12	12	26.21	2026-06-24
5082	1464	2	18	6	102.24	2026-06-24
5083	1464	34	24	24	132.21	2026-06-24
5084	1465	5	48	0	108.81	\N
5085	1465	27	12	12	16.9	2026-06-30
5086	1465	3	12	12	26.21	2026-06-30
5087	1466	5	72	0	111.03	\N
5088	1466	25	12	12	171.1	2026-06-30
5089	1467	2	18	0	104.33	\N
5090	1467	33	18	18	117.28	2026-06-24
5091	1468	9	72	72	127.29	2026-06-24
5092	1468	26	18	18	54.42	2026-06-24
5093	1468	4	36	12	37.01	2026-06-24
5094	1468	8	18	18	48.81	2026-06-24
5095	1468	5	72	72	108.81	2026-06-24
5096	1469	39	6	6	30.89	2026-06-25
5097	1469	5	24	24	105.48	2026-06-25
5098	1469	12	24	24	138.3	2026-06-25
5099	1469	6	48	35	146.84	2026-06-25
5100	1469	2	6	0	99.11	\N
5101	1470	6	72	0	151.48	\N
5102	1470	15	24	24	166.81	2026-06-25
5103	1470	25	12	12	167.68	2026-06-25
5104	1470	9	48	48	127.29	2026-06-25
5105	1471	31	24	24	142.92	2026-06-24
5106	1471	3	36	36	25.4	2026-06-24
5107	1471	33	6	6	111.42	2026-06-24
5108	1471	2	18	0	99.11	\N
5109	1471	16	24	24	153.48	2026-06-24
5110	1472	5	24	24	111.03	2026-06-24
5111	1472	20	12	12	68.61	2026-06-24
5112	1472	2	12	0	104.33	\N
5113	1472	11	18	18	195.04	2026-06-24
5114	1473	3	36	36	26.74	2026-06-25
5115	1473	24	72	72	36.72	2026-06-25
5116	1473	39	6	6	32.52	2026-06-25
5117	1473	4	24	24	37.77	2026-06-25
5118	1473	12	48	48	145.58	2026-06-25
5119	1474	16	24	24	161.56	2026-07-01
5120	1474	8	6	0	49.81	\N
5121	1474	13	36	36	97.54	2026-07-01
5122	1474	6	72	0	154.57	\N
5123	1474	4	12	12	37.77	2026-07-01
5124	1475	9	72	72	123.4	2026-06-30
5125	1475	1	18	18	11.87	2026-06-30
5126	1475	25	18	18	162.54	2026-06-30
5127	1475	27	36	5	16.38	2026-06-30
5128	1475	31	48	48	142.92	2026-06-30
5129	1476	35	12	12	118.84	2026-06-28
5130	1476	12	72	72	138.3	2026-06-28
5131	1476	4	36	24	35.88	2026-06-28
5132	1477	31	48	48	147.43	2026-06-28
5133	1477	22	12	12	162.12	2026-06-28
5134	1477	4	12	0	37.01	\N
5135	1478	8	6	6	49.81	2026-06-25
5136	1478	4	36	0	37.77	\N
5137	1478	2	18	18	104.33	2026-06-25
5138	1479	33	6	0	117.28	\N
5139	1479	31	24	24	150.44	2026-06-26
5140	1479	12	48	48	145.58	2026-06-26
5141	1480	23	36	36	45.97	2026-06-26
5142	1480	4	24	0	37.01	\N
5143	1481	3	36	36	26.74	2026-06-25
5144	1481	1	12	12	12.49	2026-06-25
5145	1481	31	24	24	150.44	2026-06-25
5146	1481	4	24	0	37.77	\N
5147	1481	23	12	12	46.91	2026-06-25
5148	1482	5	24	24	111.03	2026-06-26
5149	1482	35	12	12	125.1	2026-06-26
5150	1483	31	72	72	142.92	2026-06-26
5151	1483	32	12	12	117.97	2026-06-26
5152	1483	38	36	36	147.67	2026-06-26
5153	1483	5	24	24	105.48	2026-06-26
5154	1484	24	72	72	36.72	2026-06-29
5155	1484	38	12	12	155.44	2026-06-29
5156	1484	5	24	24	111.03	2026-06-29
5157	1484	30	24	0	184.29	\N
5158	1484	12	72	72	145.58	2026-06-29
5159	1485	6	24	0	154.57	\N
5160	1485	37	72	72	129.57	2026-07-01
5161	1486	16	24	24	153.48	2026-06-27
5162	1486	11	6	6	185.29	2026-06-27
5163	1486	14	24	24	110.38	2026-06-27
5164	1487	18	48	48	78.69	2026-06-27
5165	1487	24	48	48	34.88	2026-06-27
5166	1487	35	24	24	118.84	2026-06-27
5167	1488	1	6	6	12.24	2026-07-01
5168	1488	33	18	18	114.93	2026-07-01
5169	1488	20	12	12	67.24	2026-07-01
5170	1488	23	24	24	45.97	2026-07-01
5171	1488	26	18	18	54.42	2026-07-01
5172	1489	33	18	18	111.42	2026-07-01
5173	1489	34	12	12	128.16	2026-07-01
5174	1489	3	36	36	25.4	2026-07-01
5175	1490	11	6	6	185.29	2026-06-28
5176	1490	1	12	12	11.87	2026-06-28
5177	1490	25	18	12	162.54	2026-06-28
5178	1490	6	48	48	146.84	2026-06-28
5179	1491	33	12	12	111.42	2026-06-29
5180	1491	26	18	18	52.75	2026-06-29
5181	1492	33	12	0	117.28	\N
5182	1492	18	24	24	82.83	2026-06-28
5183	1492	3	12	12	26.74	2026-06-28
5184	1493	37	72	72	129.57	2026-06-30
5185	1493	12	72	72	145.58	2026-06-30
5186	1493	5	24	24	111.03	2026-06-30
5187	1493	38	24	24	155.44	2026-06-30
5188	1493	31	72	72	150.44	2026-06-30
5189	1494	26	18	18	52.75	2026-07-04
5190	1494	37	72	72	123.09	2026-07-04
5191	1494	35	36	36	118.84	2026-07-04
5192	1495	30	72	0	184.29	\N
5193	1495	38	12	12	155.44	2026-07-02
5194	1495	9	24	24	129.89	2026-07-02
5195	1495	28	36	12	176.24	2026-07-02
5196	1495	8	18	0	49.81	\N
5197	1496	21	72	72	58.64	2026-07-04
5198	1496	31	24	24	147.43	2026-07-04
5199	1496	27	36	0	16.9	\N
5200	1497	35	12	12	122.6	2026-07-04
5201	1497	2	18	18	102.24	2026-07-04
5202	1497	1	6	6	12.24	2026-07-04
5203	1497	37	72	72	126.98	2026-07-04
5204	1497	14	36	36	113.87	2026-07-04
5205	1498	9	48	48	127.29	2026-06-30
5206	1498	39	12	12	31.87	2026-06-30
5207	1498	31	48	48	147.43	2026-06-30
5208	1498	8	12	12	48.81	2026-06-30
5209	1498	12	48	48	142.67	2026-06-30
5210	1499	20	12	12	65.18	2026-06-30
5211	1499	4	12	12	35.88	2026-06-30
5212	1499	40	18	18	36.74	2026-06-30
5213	1500	36	72	72	119.54	2026-06-29
5214	1500	9	48	48	129.89	2026-06-29
5215	1501	7	12	6	159.96	2026-06-29
5216	1501	2	18	18	104.33	2026-06-29
5217	1501	10	48	48	74.91	2026-06-29
5218	1502	9	48	24	129.89	2026-06-30
5219	1502	10	24	24	74.91	2026-06-30
5220	1502	15	12	12	170.21	2026-06-30
5221	1503	22	12	12	157.16	2026-06-30
5222	1503	32	18	18	117.97	2026-06-30
5223	1503	4	24	24	35.88	2026-06-30
5224	1503	33	6	6	111.42	2026-06-30
5225	1504	31	24	24	150.44	2026-06-29
5226	1504	24	24	24	36.72	2026-06-29
5227	1504	5	48	48	111.03	2026-06-29
5228	1504	21	24	24	59.84	2026-06-29
5229	1505	4	24	24	37.77	2026-06-29
5230	1505	2	6	6	104.33	2026-06-29
5231	1506	1	18	18	12.49	2026-06-29
5232	1506	4	24	24	37.77	2026-06-29
5233	1507	1	6	6	12.49	2026-06-29
5234	1507	34	36	36	134.91	2026-06-29
5235	1507	39	12	12	32.52	2026-06-29
5236	1507	37	72	72	129.57	2026-06-29
5237	1507	32	6	6	124.18	2026-06-29
5238	1508	5	48	48	111.03	2026-06-30
5239	1508	31	72	72	150.44	2026-06-30
5240	1508	33	18	18	117.28	2026-06-30
5241	1509	3	24	24	25.4	2026-06-30
5242	1509	9	24	24	123.4	2026-06-30
5243	1509	5	24	24	105.48	2026-06-30
5244	1509	4	12	12	35.88	2026-06-30
5245	1509	1	18	18	11.87	2026-06-30
5246	1510	31	24	24	150.44	2026-06-30
5247	1510	12	48	48	145.58	2026-06-30
5248	1510	25	6	0	171.1	\N
5249	1511	39	12	12	32.52	2026-06-30
5250	1511	12	24	24	145.58	2026-06-30
5251	1511	19	48	48	153.58	2026-06-30
5252	1511	14	36	36	116.19	2026-06-30
5253	1512	16	24	24	158.33	2026-07-01
5254	1512	6	48	48	151.48	2026-07-01
5255	1512	12	48	48	142.67	2026-07-01
5256	1512	37	48	48	126.98	2026-07-01
5257	1513	31	24	24	150.44	2026-07-05
5258	1513	4	36	36	37.77	2026-07-05
5259	1513	29	12	0	47.33	\N
5260	1513	34	12	12	134.91	2026-07-05
5261	1513	15	36	36	170.21	2026-07-05
5262	1514	38	24	24	147.67	2026-07-04
5263	1514	4	24	24	35.88	2026-07-04
5264	1515	20	12	12	67.24	2026-07-06
5265	1515	3	36	36	26.21	2026-07-06
5266	1515	15	36	36	166.81	2026-07-06
5267	1516	1	6	6	12.49	2026-07-06
5268	1516	11	18	18	195.04	2026-07-06
5269	1516	25	6	6	171.1	2026-07-06
5270	1517	31	72	72	150.44	2026-07-03
5271	1517	26	6	6	55.53	2026-07-03
5272	1517	1	12	12	12.49	2026-07-03
5273	1518	12	48	48	142.67	2026-07-05
5274	1518	17	6	6	51.95	2026-07-05
5275	1518	2	12	12	102.24	2026-07-05
5276	1518	14	36	0	113.87	\N
5277	1519	2	18	18	99.11	2026-07-01
5278	1519	40	12	12	36.74	2026-07-01
5279	1519	4	12	12	35.88	2026-07-01
5280	1520	24	72	72	36.72	2026-06-30
5281	1520	13	12	0	97.54	\N
5282	1521	4	12	12	35.88	2026-07-01
5283	1521	8	12	12	47.32	2026-07-01
5284	1521	37	72	72	123.09	2026-07-01
5285	1522	31	48	48	150.44	2026-07-01
5286	1522	20	12	12	68.61	2026-07-01
5287	1522	3	12	12	26.74	2026-07-01
5288	1523	22	6	6	157.16	2026-07-01
5289	1523	39	12	12	30.89	2026-07-01
5290	1524	16	24	24	153.48	2026-07-01
5291	1524	1	18	12	11.87	2026-07-01
5292	1524	31	72	72	142.92	2026-07-01
5293	1524	4	24	24	35.88	2026-07-01
5294	1525	2	6	6	104.33	2026-07-01
5295	1525	5	72	72	111.03	2026-07-01
5296	1525	3	24	24	26.74	2026-07-01
5297	1525	13	24	24	97.54	2026-07-01
5298	1525	6	48	48	154.57	2026-07-01
5299	1526	12	72	72	145.58	2026-07-07
5300	1526	6	24	24	154.57	2026-07-07
5301	1526	39	6	6	32.52	2026-07-07
5302	1526	26	18	18	55.53	2026-07-07
5303	1526	37	24	24	129.57	2026-07-07
5304	1527	16	24	24	161.56	2026-07-04
5305	1527	4	36	36	37.77	2026-07-04
5306	1527	23	24	0	46.91	\N
5307	1528	2	12	12	104.33	2026-07-06
5308	1528	5	24	24	111.03	2026-07-06
5309	1528	31	24	24	150.44	2026-07-06
5310	1529	16	36	36	161.56	2026-07-07
5311	1529	2	6	6	104.33	2026-07-07
5312	1529	9	24	24	129.89	2026-07-07
5313	1529	12	72	72	145.58	2026-07-07
5314	1530	12	48	48	145.58	2026-07-05
5315	1530	30	48	0	184.29	\N
5316	1530	37	48	48	129.57	2026-07-05
5317	1530	4	24	24	37.77	2026-07-05
5318	1530	8	18	18	49.81	2026-07-05
5319	1531	9	24	24	129.89	2026-07-05
5320	1531	5	72	72	111.03	2026-07-05
5321	1532	12	72	72	142.67	2026-07-04
5322	1532	6	48	48	151.48	2026-07-04
5323	1532	2	18	18	102.24	2026-07-04
5324	1533	5	24	24	111.03	2026-07-01
5325	1533	4	12	12	37.77	2026-07-01
5326	1533	1	12	12	12.49	2026-07-01
5327	1533	21	24	24	59.84	2026-07-01
5328	1533	33	18	18	117.28	2026-07-01
5329	1534	10	48	24	71.16	2026-07-02
5330	1534	4	36	36	35.88	2026-07-02
5331	1535	24	24	24	34.88	2026-07-05
5332	1535	33	6	6	111.42	2026-07-05
5333	1535	39	6	6	30.89	2026-07-05
5334	1536	16	24	24	161.56	2026-07-05
5335	1536	12	72	72	145.58	2026-07-05
5336	1536	4	24	24	37.77	2026-07-05
5337	1536	26	6	6	55.53	2026-07-05
5338	1536	27	36	0	17.24	\N
5339	1537	36	24	24	117.15	2026-07-06
5340	1537	28	36	0	172.72	\N
5341	1537	29	12	0	46.38	\N
5342	1537	9	72	0	127.29	\N
5343	1538	25	12	12	171.1	2026-07-02
5344	1538	5	24	24	111.03	2026-07-02
5345	1539	2	6	6	104.33	2026-07-03
5346	1539	31	24	24	150.44	2026-07-03
5347	1539	5	24	24	111.03	2026-07-03
5348	1539	4	36	36	37.77	2026-07-03
5349	1540	2	18	18	104.33	2026-07-03
5350	1540	4	36	12	37.77	2026-07-03
5351	1541	2	6	6	104.33	2026-07-03
5352	1541	35	36	36	125.1	2026-07-03
5353	1542	16	24	24	153.48	2026-07-04
5354	1542	2	6	6	99.11	2026-07-04
5355	1542	13	24	24	92.66	2026-07-04
5356	1542	5	72	72	105.48	2026-07-04
5357	1542	40	18	18	36.74	2026-07-04
5358	1543	26	6	6	55.53	2026-07-03
5359	1543	6	48	48	154.57	2026-07-03
5360	1543	27	36	0	17.24	\N
5361	1543	4	24	24	37.77	2026-07-03
5362	1544	2	18	18	104.33	2026-07-04
5363	1544	5	24	24	111.03	2026-07-04
5364	1544	13	24	24	97.54	2026-07-04
5365	1545	6	24	24	151.48	2026-07-03
5366	1545	26	12	12	54.42	2026-07-03
5367	1546	3	24	24	26.21	2026-07-08
5368	1546	18	72	72	81.17	2026-07-08
5369	1546	4	12	12	37.01	2026-07-08
5370	1547	35	12	12	118.84	2026-07-09
5371	1547	1	18	18	11.87	2026-07-09
5372	1548	12	48	48	145.58	2026-07-08
5373	1548	8	18	18	49.81	2026-07-08
5374	1548	4	36	0	37.77	\N
5375	1548	38	12	12	155.44	2026-07-08
5376	1548	39	12	12	32.52	2026-07-08
5377	1549	19	24	24	153.58	2026-07-07
5378	1549	3	24	0	26.74	\N
5379	1549	32	18	18	124.18	2026-07-07
5380	1549	2	6	6	104.33	2026-07-07
5381	1550	39	12	12	32.52	2026-07-06
5382	1550	33	12	12	117.28	2026-07-06
5383	1551	3	36	36	25.4	2026-07-03
5384	1551	39	12	12	30.89	2026-07-03
5385	1552	24	72	72	36.72	2026-07-03
5386	1552	6	24	0	154.57	\N
5387	1552	1	12	12	12.49	2026-07-03
5388	1552	14	24	24	116.19	2026-07-03
5389	1552	16	36	36	161.56	2026-07-03
5390	1553	3	36	36	26.74	2026-07-04
5391	1553	2	18	6	104.33	2026-07-04
5392	1553	10	48	15	74.91	2026-07-04
5393	1553	15	12	12	170.21	2026-07-04
5394	1554	5	72	22	111.03	2026-07-04
5395	1554	7	6	5	159.96	2026-07-04
5396	1554	11	12	12	195.04	2026-07-04
5397	1554	6	48	48	154.57	2026-07-04
5398	1555	4	24	24	37.77	2026-07-05
5399	1555	38	36	36	155.44	2026-07-05
5400	1555	13	12	12	97.54	2026-07-05
5401	1556	31	48	48	150.44	2026-07-04
5402	1556	5	24	0	111.03	\N
5403	1557	33	6	6	117.28	2026-07-04
5404	1557	31	24	24	150.44	2026-07-04
5405	1558	2	12	0	99.11	\N
5406	1558	4	36	0	35.88	\N
5407	1558	1	18	6	11.87	2026-07-04
5408	1558	20	6	6	65.18	2026-07-04
5409	1559	2	6	6	104.33	2026-07-06
5410	1559	20	12	12	68.61	2026-07-06
5411	1559	15	36	36	170.21	2026-07-06
5412	1559	33	6	6	117.28	2026-07-06
5413	1560	7	6	6	151.96	2026-07-05
5414	1560	25	18	0	162.54	\N
5415	1560	9	72	72	123.4	2026-07-05
5416	1560	4	24	24	35.88	2026-07-05
5417	1561	11	18	16	195.04	2026-07-11
5418	1561	5	48	48	111.03	2026-07-11
5419	1561	37	48	48	129.57	2026-07-11
5420	1562	16	24	24	158.33	2026-07-08
5421	1562	4	24	24	37.01	2026-07-08
5422	1562	1	12	12	12.24	2026-07-08
5423	1562	8	18	5	48.81	2026-07-08
5424	1563	3	24	24	26.74	2026-07-05
5425	1563	22	12	12	165.43	2026-07-05
5426	1563	5	72	72	111.03	2026-07-05
5427	1564	8	12	12	49.81	2026-07-05
5428	1564	12	24	24	145.58	2026-07-05
5429	1564	38	24	24	155.44	2026-07-05
5430	1565	12	48	48	145.58	2026-07-05
5431	1565	15	36	36	170.21	2026-07-05
5432	1566	6	24	24	154.57	2026-07-06
5433	1566	11	6	6	195.04	2026-07-06
5434	1567	31	24	24	147.43	2026-07-07
5435	1567	20	18	18	67.24	2026-07-07
5436	1567	5	48	0	108.81	\N
5437	1568	2	18	0	104.33	\N
5438	1568	5	72	72	111.03	2026-07-06
5439	1568	4	12	0	37.77	\N
5440	1569	31	48	48	150.44	2026-07-06
5441	1569	13	24	24	97.54	2026-07-06
5442	1569	8	18	18	49.81	2026-07-06
5443	1569	2	6	0	104.33	\N
5444	1570	40	6	6	38.67	2026-07-07
5445	1570	4	24	24	37.77	2026-07-07
5446	1570	1	6	6	12.49	2026-07-07
5447	1570	9	24	24	129.89	2026-07-07
5448	1571	25	6	6	171.1	2026-07-08
5449	1571	5	24	0	111.03	\N
5450	1571	30	48	48	184.29	2026-07-08
5451	1571	31	24	24	150.44	2026-07-08
5452	1571	3	24	24	26.74	2026-07-08
5453	1572	7	6	3	159.96	2026-07-11
5454	1572	8	12	12	49.81	2026-07-11
5455	1572	3	12	0	26.74	\N
5456	1572	15	36	36	170.21	2026-07-11
5457	1572	9	24	0	129.89	\N
5458	1573	13	36	36	97.54	2026-07-12
5459	1573	33	18	18	117.28	2026-07-12
5460	1574	1	12	12	12.49	2026-07-10
5461	1574	35	12	12	125.1	2026-07-10
5462	1574	16	24	24	161.56	2026-07-10
5463	1575	31	72	72	142.92	2026-07-13
5464	1575	40	18	18	36.74	2026-07-13
5465	1575	34	24	24	128.16	2026-07-13
5466	1576	7	6	0	159.96	\N
5467	1576	21	24	24	59.84	2026-07-11
5468	1576	3	12	0	26.74	\N
5469	1576	29	12	12	47.33	2026-07-11
5470	1577	35	24	24	125.1	2026-07-07
5471	1577	8	12	12	49.81	2026-07-07
5472	1578	13	12	12	92.66	2026-07-08
5473	1578	23	36	36	44.56	2026-07-08
5474	1578	33	6	6	111.42	2026-07-08
5475	1579	6	48	48	154.57	2026-07-08
5476	1579	12	24	24	145.58	2026-07-08
5477	1580	4	24	24	37.77	2026-07-08
5478	1580	12	48	48	145.58	2026-07-08
5479	1580	27	24	24	17.24	2026-07-08
5480	1581	30	24	24	184.29	2026-07-08
5481	1581	25	18	18	171.1	2026-07-08
5482	1581	24	72	72	36.72	2026-07-08
5483	1582	31	48	48	150.44	2026-07-09
5484	1582	12	72	72	145.58	2026-07-09
5485	1583	28	12	12	176.24	2026-07-09
5486	1583	33	18	18	117.28	2026-07-09
5487	1583	2	12	12	104.33	2026-07-09
5488	1583	7	12	12	159.96	2026-07-09
5489	1583	37	48	48	129.57	2026-07-09
5490	1584	37	48	48	126.98	2026-07-14
5491	1584	9	24	0	127.29	\N
5492	1584	17	18	18	51.95	2026-07-14
5493	1585	12	48	48	145.58	2026-07-12
5494	1585	25	18	18	171.1	2026-07-12
5495	1585	35	36	36	125.1	2026-07-12
5496	1586	9	24	0	127.29	\N
5497	1586	2	6	6	102.24	2026-07-11
5498	1586	4	36	36	37.01	2026-07-11
5499	1587	4	36	36	37.77	2026-07-14
5500	1587	12	24	24	145.58	2026-07-14
5501	1587	25	6	6	171.1	2026-07-14
5502	1588	4	24	0	37.77	\N
5503	1588	3	12	12	26.74	2026-07-08
5504	1589	16	12	12	161.56	2026-07-08
5505	1589	3	36	0	26.74	\N
5506	1589	15	36	36	170.21	2026-07-08
5507	1590	9	48	0	129.89	\N
5508	1590	17	6	6	53.01	2026-07-09
5509	1590	10	72	0	74.91	\N
5510	1590	12	48	48	145.58	2026-07-09
5511	1591	9	48	0	129.89	\N
5512	1591	4	36	0	37.77	\N
5513	1592	22	18	18	165.43	2026-07-08
5514	1592	2	12	0	104.33	\N
5515	1592	36	72	72	119.54	2026-07-08
5516	1593	31	48	48	142.92	2026-07-09
5517	1593	30	24	24	175.08	2026-07-09
5518	1593	18	72	58	78.69	2026-07-09
5519	1593	15	24	24	161.7	2026-07-09
5520	1593	33	18	18	111.42	2026-07-09
5521	1594	12	72	72	145.58	2026-07-09
5522	1594	1	12	12	12.49	2026-07-09
5523	1595	31	72	72	142.92	2026-07-14
5524	1595	18	24	24	78.69	2026-07-14
5525	1595	12	24	0	138.3	\N
5526	1595	29	18	18	44.96	2026-07-14
5527	1595	9	48	0	123.4	\N
5528	1596	2	6	6	99.11	2026-07-14
5529	1596	8	18	18	47.32	2026-07-14
5530	1596	5	24	24	105.48	2026-07-14
5531	1596	12	48	0	138.3	\N
5532	1597	15	24	24	170.21	2026-07-14
5533	1597	37	72	72	129.57	2026-07-14
5534	1597	9	24	0	129.89	\N
5535	1597	11	18	18	195.04	2026-07-14
5536	1597	31	24	24	150.44	2026-07-14
5537	1598	15	12	12	166.81	2026-07-10
5538	1598	14	36	36	113.87	2026-07-10
5539	1598	33	18	18	114.93	2026-07-10
5540	1598	21	48	48	58.64	2026-07-10
5541	1599	2	6	6	104.33	2026-07-09
5542	1599	39	6	6	32.52	2026-07-09
5543	1599	9	72	0	129.89	\N
5544	1599	16	12	12	161.56	2026-07-09
5545	1599	4	24	0	37.77	\N
5546	1600	12	72	72	142.67	2026-07-10
5547	1600	4	36	0	37.01	\N
5548	1601	37	24	24	129.57	2026-07-09
5549	1601	33	6	6	117.28	2026-07-09
5550	1601	11	6	6	195.04	2026-07-09
5551	1601	6	24	24	154.57	2026-07-09
5552	1601	10	24	0	74.91	\N
5553	1602	22	6	6	165.43	2026-07-09
5554	1602	9	72	0	129.89	\N
5555	1602	16	12	12	161.56	2026-07-09
5556	1602	3	36	0	26.74	\N
5557	1603	4	12	0	37.77	\N
5558	1603	23	24	24	46.91	2026-07-09
5559	1603	9	72	0	129.89	\N
5560	1603	15	36	36	170.21	2026-07-09
5561	1604	8	18	18	48.81	2026-07-10
5562	1604	2	18	18	102.24	2026-07-10
5563	1604	15	36	36	166.81	2026-07-10
5564	1604	26	6	6	54.42	2026-07-10
5565	1604	31	24	24	147.43	2026-07-10
5566	1605	2	12	12	104.33	2026-07-11
5567	1605	14	36	36	116.19	2026-07-11
5568	1605	29	12	12	47.33	2026-07-11
5569	1605	23	36	36	46.91	2026-07-11
5570	1605	5	48	0	111.03	\N
5571	1606	38	12	12	155.44	2026-07-14
5572	1606	2	12	12	104.33	2026-07-14
5573	1606	8	6	6	49.81	2026-07-14
5574	1606	4	36	36	37.77	2026-07-14
5575	1607	9	48	0	127.29	\N
5576	1607	17	12	12	51.95	2026-07-10
5577	1607	1	18	18	12.24	2026-07-10
5578	1607	19	48	48	150.51	2026-07-10
5579	1607	7	6	6	156.76	2026-07-10
5580	1608	30	48	48	184.29	2026-07-10
5581	1608	39	6	6	32.52	2026-07-10
5582	1608	38	12	12	155.44	2026-07-10
5583	1608	37	24	24	129.57	2026-07-10
5584	1608	10	72	0	74.91	\N
5585	1609	12	72	72	138.3	2026-07-10
5586	1609	38	36	36	147.67	2026-07-10
5587	1609	5	24	24	105.48	2026-07-10
5588	1609	16	24	24	153.48	2026-07-10
5589	1610	6	24	24	154.57	2026-07-10
5590	1610	37	24	24	129.57	2026-07-10
5591	1610	24	48	48	36.72	2026-07-10
5592	1611	4	12	12	35.88	2026-07-10
5593	1611	2	18	18	99.11	2026-07-10
5594	1611	5	72	48	105.48	2026-07-10
5595	1611	8	12	0	47.32	\N
5596	1611	26	18	18	52.75	2026-07-10
5597	1612	13	24	24	92.66	2026-07-10
5598	1612	9	72	0	123.4	\N
5599	1613	2	18	12	104.33	2026-07-11
5600	1613	11	6	6	195.04	2026-07-11
5601	1614	4	36	36	37.77	2026-07-14
5602	1614	35	24	24	125.1	2026-07-14
5603	1614	2	18	18	104.33	2026-07-14
5604	1614	33	18	18	117.28	2026-07-14
5605	1614	8	12	12	49.81	2026-07-14
5606	1615	20	12	12	68.61	2026-07-11
5607	1615	12	72	72	145.58	2026-07-11
5608	1615	5	48	0	111.03	\N
5609	1616	8	6	6	47.32	2026-07-13
5610	1616	31	48	48	142.92	2026-07-13
5611	1616	22	18	18	157.16	2026-07-13
5612	1616	12	24	24	138.3	2026-07-13
5613	1616	9	72	72	123.4	2026-07-13
5614	1617	28	12	12	176.24	2026-07-14
5615	1617	21	48	48	59.84	2026-07-14
5616	1617	25	18	18	171.1	2026-07-14
5617	1618	16	36	36	153.48	2026-07-14
5618	1618	2	18	0	99.11	\N
5619	1618	23	12	12	44.56	2026-07-14
5620	1618	9	48	48	123.4	2026-07-14
5621	1618	31	24	0	142.92	\N
5622	1619	4	24	12	35.88	2026-07-19
5623	1619	1	18	18	11.87	2026-07-19
5624	1620	37	72	72	126.98	2026-07-16
5625	1620	23	24	24	45.97	2026-07-16
5626	1621	1	12	12	11.87	2026-07-17
5627	1621	30	72	72	175.08	2026-07-17
5628	1622	1	6	6	12.49	2026-07-16
5629	1622	4	24	0	37.77	\N
5630	1623	23	24	24	46.91	2026-07-13
5631	1623	37	24	24	129.57	2026-07-13
5632	1623	2	6	6	104.33	2026-07-13
5633	1623	11	12	12	195.04	2026-07-13
5634	1624	5	72	0	108.81	\N
5635	1624	2	12	12	102.24	2026-07-13
5636	1624	39	6	6	31.87	2026-07-13
5637	1624	25	12	12	167.68	2026-07-13
5638	1624	9	72	0	127.29	\N
5639	1625	5	24	0	108.81	\N
5640	1625	1	6	6	12.24	2026-07-13
5641	1625	21	48	48	58.64	2026-07-13
5642	1625	4	12	12	37.01	2026-07-13
5643	1626	1	6	6	12.49	2026-07-14
5644	1626	16	36	36	161.56	2026-07-14
5645	1626	13	12	12	97.54	2026-07-14
5646	1626	9	24	24	129.89	2026-07-14
5647	1627	24	48	48	36.72	2026-07-14
5648	1627	25	6	6	171.1	2026-07-14
5649	1628	1	6	6	12.49	2026-07-17
5650	1628	2	12	12	104.33	2026-07-17
5651	1629	37	72	72	126.98	2026-07-19
5652	1629	31	72	72	147.43	2026-07-19
5653	1630	4	36	36	35.88	2026-07-14
5654	1630	2	12	12	99.11	2026-07-14
5655	1630	14	24	24	110.38	2026-07-14
5656	1630	31	24	24	142.92	2026-07-14
5657	1630	23	36	0	44.56	\N
5658	1631	4	12	12	37.01	2026-07-14
5659	1631	8	18	0	48.81	\N
5660	1632	39	12	12	32.52	2026-07-15
5661	1632	5	72	0	111.03	\N
5662	1632	38	36	36	155.44	2026-07-15
5663	1633	5	24	24	111.03	2026-07-16
5664	1633	4	24	24	37.77	2026-07-16
5665	1633	13	12	12	97.54	2026-07-16
5666	1633	12	24	24	145.58	2026-07-16
5667	1634	4	36	0	37.01	\N
5668	1634	39	12	12	31.87	2026-07-15
5669	1634	5	48	48	108.81	2026-07-15
5670	1634	29	18	18	46.38	2026-07-15
5671	1635	14	24	24	116.19	2026-07-18
5672	1635	3	36	36	26.74	2026-07-18
5673	1635	33	6	6	117.28	2026-07-18
5674	1636	4	12	12	35.88	2026-07-15
5675	1636	33	12	12	111.42	2026-07-15
5676	1636	16	24	24	153.48	2026-07-15
5677	1637	8	18	0	47.32	\N
5678	1637	23	12	0	44.56	\N
5679	1637	16	24	24	153.48	2026-07-16
5680	1637	12	48	48	138.3	2026-07-16
5681	1638	5	72	0	111.03	\N
5682	1638	36	24	24	119.54	2026-07-16
5683	1638	2	12	12	104.33	2026-07-16
5684	1638	32	12	12	124.18	2026-07-16
5685	1638	31	72	72	150.44	2026-07-16
5686	1639	5	24	24	111.03	2026-07-16
5687	1639	2	6	0	104.33	\N
5688	1640	10	48	0	74.91	\N
5689	1640	31	72	72	150.44	2026-07-16
5690	1640	25	6	6	171.1	2026-07-16
5691	1640	12	24	24	145.58	2026-07-16
5692	1640	16	36	36	161.56	2026-07-16
5693	1641	6	48	48	151.48	2026-07-22
5694	1641	26	18	12	54.42	2026-07-22
5695	1641	18	48	48	81.17	2026-07-22
5696	1641	38	24	24	152.33	2026-07-22
5697	1642	30	24	24	184.29	2026-07-22
5698	1642	2	12	12	104.33	2026-07-22
5699	1643	22	12	12	162.12	2026-07-16
5700	1643	2	6	6	102.24	2026-07-16
5701	1643	6	24	24	151.48	2026-07-16
5702	1644	32	12	12	117.97	2026-07-16
5703	1644	1	18	18	11.87	2026-07-16
5704	1644	15	12	12	161.7	2026-07-16
5705	1644	40	18	18	36.74	2026-07-16
5706	1645	34	36	36	128.16	2026-07-16
5707	1645	36	24	24	113.56	2026-07-16
5708	1645	37	24	24	123.09	2026-07-16
5709	1646	31	72	72	150.44	2026-07-18
5710	1646	33	12	12	117.28	2026-07-18
5711	1646	40	12	12	38.67	2026-07-18
5712	1646	4	24	24	37.77	2026-07-18
5713	1647	13	36	36	97.54	2026-07-17
5714	1647	21	48	48	59.84	2026-07-17
5715	1647	6	72	0	154.57	\N
5716	1647	31	48	48	150.44	2026-07-17
5717	1647	22	12	12	165.43	2026-07-17
5718	1648	22	6	6	165.43	2026-07-21
5719	1648	18	72	72	82.83	2026-07-21
5720	1649	39	6	6	32.52	2026-07-21
5721	1649	2	12	12	104.33	2026-07-21
5722	1650	31	48	48	142.92	2026-07-23
5723	1650	5	48	48	105.48	2026-07-23
5724	1650	1	6	6	11.87	2026-07-23
5725	1650	25	6	6	162.54	2026-07-23
5726	1650	14	24	24	110.38	2026-07-23
5727	1651	22	12	12	165.43	2026-07-22
5728	1651	27	24	24	17.24	2026-07-22
5729	1651	8	6	0	49.81	\N
5730	1651	4	24	24	37.77	2026-07-22
5731	1652	22	12	12	162.12	2026-07-21
5732	1652	17	6	6	51.95	2026-07-21
5733	1653	4	36	36	35.88	2026-07-23
5734	1653	15	24	24	161.7	2026-07-23
5735	1654	31	24	24	150.44	2026-07-19
5736	1654	32	6	6	124.18	2026-07-19
5737	1654	35	24	24	125.1	2026-07-19
5738	1655	2	12	12	99.11	2026-07-20
5739	1655	8	18	18	47.32	2026-07-20
5740	1655	31	24	24	142.92	2026-07-20
5741	1655	12	24	24	138.3	2026-07-20
5742	1656	2	18	18	99.11	2026-07-20
5743	1656	31	48	48	142.92	2026-07-20
5744	1656	11	12	12	185.29	2026-07-20
5745	1657	3	36	36	26.74	2026-07-20
5746	1657	2	6	6	104.33	2026-07-20
5747	1657	39	18	18	32.52	2026-07-20
5748	1657	5	72	72	111.03	2026-07-20
5749	1657	4	24	24	37.77	2026-07-20
5750	1658	16	24	24	161.56	2026-07-20
5751	1658	33	6	6	117.28	2026-07-20
5752	1659	16	12	12	153.48	2026-07-20
5753	1659	25	6	6	162.54	2026-07-20
5754	1659	1	18	18	11.87	2026-07-20
5755	1659	6	72	0	146.84	\N
5756	1659	3	36	36	25.4	2026-07-20
5757	1660	27	12	12	17.24	2026-07-25
5758	1660	33	18	18	117.28	2026-07-25
5759	1660	39	6	6	32.52	2026-07-25
5760	1660	8	6	0	49.81	\N
5761	1660	31	72	72	150.44	2026-07-25
5762	1661	24	48	48	36.72	2026-07-20
5763	1661	4	12	12	37.77	2026-07-20
5764	1662	2	6	6	102.24	2026-07-21
5765	1662	10	48	0	73.41	\N
5766	1662	31	24	24	147.43	2026-07-21
5767	1662	5	72	72	108.81	2026-07-21
5768	1663	16	12	12	161.56	2026-07-22
5769	1663	5	24	24	111.03	2026-07-22
5770	1664	31	48	48	150.44	2026-07-21
5771	1664	33	12	12	117.28	2026-07-21
5772	1665	15	12	12	166.81	2026-07-22
5773	1665	2	6	6	102.24	2026-07-22
5774	1665	5	72	72	108.81	2026-07-22
5775	1665	39	12	12	31.87	2026-07-22
5776	1665	12	72	72	142.67	2026-07-22
5777	1666	1	18	18	12.49	2026-07-21
5778	1666	23	12	12	46.91	2026-07-21
5779	1667	24	72	72	35.99	2026-07-21
5780	1667	17	6	6	51.95	2026-07-21
5781	1667	22	12	12	162.12	2026-07-21
5782	1667	37	24	24	126.98	2026-07-21
5783	1668	26	6	6	52.75	2026-07-21
5784	1668	31	24	24	142.92	2026-07-21
5785	1668	20	12	12	65.18	2026-07-21
5786	1668	35	12	12	118.84	2026-07-21
5787	1669	5	24	24	111.03	2026-07-26
5788	1669	35	36	36	125.1	2026-07-26
5789	1669	4	24	24	37.77	2026-07-26
5790	1669	26	6	0	55.53	\N
5791	1669	38	36	36	155.44	2026-07-26
5792	1670	5	72	72	105.48	2026-07-24
5793	1670	31	24	24	142.92	2026-07-24
5794	1670	37	72	72	123.09	2026-07-24
5795	1670	2	18	18	99.11	2026-07-24
5796	1670	9	48	48	123.4	2026-07-24
5797	1671	27	24	24	17.24	2026-07-27
5798	1671	3	36	36	26.74	2026-07-27
5799	1672	26	6	0	54.42	\N
5800	1672	24	48	48	35.99	2026-07-27
5801	1673	36	24	24	113.56	2026-07-27
5802	1673	33	18	18	111.42	2026-07-27
5803	1673	22	6	6	157.16	2026-07-27
5804	1673	7	12	12	151.96	2026-07-27
5805	1673	26	18	0	52.75	\N
5806	1674	37	24	24	129.57	2026-07-24
5807	1674	39	18	18	32.52	2026-07-24
5808	1674	22	18	18	165.43	2026-07-24
5809	1674	26	18	0	55.53	\N
5810	1674	32	6	6	124.18	2026-07-24
5811	1675	29	6	6	44.96	2026-07-24
5812	1675	15	24	24	161.7	2026-07-24
5813	1675	22	18	18	157.16	2026-07-24
5814	1675	31	24	24	142.92	2026-07-24
5815	1675	4	24	24	35.88	2026-07-24
5816	1676	26	12	12	52.75	2026-07-21
5817	1676	9	24	24	123.4	2026-07-21
5818	1676	12	24	24	138.3	2026-07-21
5819	1676	7	6	6	151.96	2026-07-21
5820	1676	35	24	24	118.84	2026-07-21
5821	1677	24	48	48	36.72	2026-07-21
5822	1677	18	72	72	82.83	2026-07-21
5823	1677	23	24	0	46.91	\N
5824	1678	31	24	24	150.44	2026-07-22
5825	1678	18	72	72	82.83	2026-07-22
5826	1679	19	24	24	153.58	2026-07-23
5827	1679	29	6	6	47.33	2026-07-23
5828	1679	22	18	18	165.43	2026-07-23
5829	1679	20	12	12	68.61	2026-07-23
5830	1680	18	72	0	78.69	\N
5831	1680	37	48	48	123.09	2026-07-23
5832	1680	4	24	24	35.88	2026-07-23
5833	1680	20	12	12	65.18	2026-07-23
5834	1680	8	12	12	47.32	2026-07-23
5835	1681	28	12	12	176.24	2026-07-22
5836	1681	29	6	6	47.33	2026-07-22
5837	1682	13	24	24	97.54	2026-07-22
5838	1682	2	18	18	104.33	2026-07-22
5839	1683	16	24	8	153.48	2026-07-23
5840	1683	5	24	24	105.48	2026-07-23
5841	1683	29	18	18	44.96	2026-07-23
5842	1683	4	36	36	35.88	2026-07-23
5843	1684	15	12	12	166.81	2026-07-22
5844	1684	20	6	6	67.24	2026-07-22
5845	1684	35	36	36	122.6	2026-07-22
5846	1684	2	12	12	102.24	2026-07-22
5847	1684	38	24	24	152.33	2026-07-22
5848	1685	4	24	24	35.88	2026-07-25
5849	1685	8	6	0	47.32	\N
5850	1685	31	48	48	142.92	2026-07-25
5851	1686	5	48	48	111.03	2026-07-28
5852	1686	3	36	36	26.74	2026-07-28
5853	1686	14	12	12	116.19	2026-07-28
5854	1687	18	24	24	82.83	2026-07-26
5855	1687	3	12	12	26.74	2026-07-26
5856	1687	11	6	6	195.04	2026-07-26
5857	1687	37	72	72	129.57	2026-07-26
5858	1688	5	24	24	108.81	2026-07-28
5859	1688	8	6	0	48.81	\N
5860	1689	3	12	12	25.4	2026-07-23
5861	1689	1	12	12	11.87	2026-07-23
5862	1689	21	48	48	56.85	2026-07-23
5863	1690	37	72	72	129.57	2026-07-27
5864	1690	2	12	12	104.33	2026-07-27
5865	1690	5	48	48	111.03	2026-07-27
5866	1691	12	24	24	138.3	2026-07-27
5867	1691	15	12	12	161.7	2026-07-27
5868	1691	16	12	12	153.48	2026-07-27
5869	1692	20	18	18	67.24	2026-07-26
5870	1692	2	6	6	102.24	2026-07-26
5871	1692	37	48	48	126.98	2026-07-26
5872	1692	5	48	48	108.81	2026-07-26
5873	1692	26	12	0	54.42	\N
5874	1693	33	6	6	117.28	2026-07-24
5875	1693	4	36	36	37.77	2026-07-24
5876	1693	15	36	36	170.21	2026-07-24
5877	1694	19	24	24	153.58	2026-07-23
5878	1694	39	6	6	32.52	2026-07-23
5879	1695	33	18	18	117.28	2026-07-24
5880	1695	5	24	24	111.03	2026-07-24
5881	1696	12	48	48	145.58	2026-07-24
5882	1696	5	48	48	111.03	2026-07-24
5883	1696	20	12	12	68.61	2026-07-24
5884	1696	39	12	12	32.52	2026-07-24
5885	1696	8	18	0	49.81	\N
5886	1697	14	12	12	116.19	2026-07-23
5887	1697	5	24	24	111.03	2026-07-23
5888	1697	16	36	36	161.56	2026-07-23
5889	1697	37	72	72	129.57	2026-07-23
5890	1697	23	12	0	46.91	\N
5891	1698	16	12	0	158.33	\N
5892	1698	5	72	72	108.81	2026-07-25
5893	1698	6	48	0	151.48	\N
5894	1698	20	18	18	67.24	2026-07-25
5895	1699	24	72	72	36.72	2026-07-29
5896	1699	18	72	72	82.83	2026-07-29
5897	1699	1	12	12	12.49	2026-07-29
5898	1700	26	18	0	54.42	\N
5899	1700	16	12	12	158.33	2026-07-30
5900	1700	33	18	18	114.93	2026-07-30
5901	1701	31	24	24	150.44	2026-07-29
5902	1701	6	24	24	154.57	2026-07-29
5903	1701	37	24	24	129.57	2026-07-29
5904	1701	14	36	36	116.19	2026-07-29
5905	1702	33	6	6	117.28	2026-07-28
5906	1702	10	24	24	74.91	2026-07-28
5907	1702	1	18	0	12.49	\N
5908	1702	8	12	0	49.81	\N
5909	1702	3	24	24	26.74	2026-07-28
5910	1703	9	24	24	127.29	2026-07-24
5911	1703	6	48	48	151.48	2026-07-24
5912	1704	16	24	24	161.56	2026-07-25
5913	1704	26	6	6	55.53	2026-07-25
5914	1704	3	24	24	26.74	2026-07-25
5915	1704	24	24	24	36.72	2026-07-25
5916	1704	32	18	18	124.18	2026-07-25
5917	1705	22	6	1	162.12	2026-07-25
5918	1705	12	72	72	142.67	2026-07-25
5919	1705	2	6	6	102.24	2026-07-25
5920	1705	35	12	12	122.6	2026-07-25
5921	1705	3	36	24	26.21	2026-07-25
5922	1706	8	18	0	49.81	\N
5923	1706	1	6	6	12.49	2026-07-31
5924	1706	15	36	36	170.21	2026-07-31
5925	1707	31	24	24	142.92	2026-07-25
5926	1707	5	48	48	105.48	2026-07-25
5927	1708	14	12	12	116.19	2026-07-25
5928	1708	34	24	24	134.91	2026-07-25
5929	1708	6	48	48	154.57	2026-07-25
5930	1709	3	36	36	25.4	2026-07-31
5931	1709	7	18	13	151.96	2026-07-31
5932	1709	16	24	24	153.48	2026-07-31
5933	1709	18	48	48	78.69	2026-07-31
5934	1710	4	36	36	35.88	2026-07-27
5935	1710	13	12	12	92.66	2026-07-27
5936	1710	6	48	48	146.84	2026-07-27
5937	1711	26	12	12	52.75	2026-07-28
5938	1711	31	72	72	142.92	2026-07-28
5939	1712	37	24	24	126.98	2026-07-27
5940	1712	15	12	12	166.81	2026-07-27
5941	1712	12	72	72	142.67	2026-07-27
5942	1713	12	24	24	145.58	2026-07-31
5943	1713	39	12	12	32.52	2026-07-31
5944	1713	31	48	48	150.44	2026-07-31
5945	1713	29	18	18	47.33	2026-07-31
5946	1714	26	12	0	52.75	\N
5947	1714	1	18	18	11.87	2026-07-31
5948	1714	37	48	48	123.09	2026-07-31
5949	1714	5	72	24	105.48	2026-07-31
5950	1715	33	12	12	114.93	2026-07-31
5951	1715	6	24	24	151.48	2026-07-31
5952	1715	15	12	12	166.81	2026-07-31
5953	1716	5	48	0	111.03	\N
5954	1716	37	24	24	129.57	2026-07-30
5955	1717	33	12	12	117.28	2026-07-27
5956	1717	5	72	72	111.03	2026-07-27
5957	1717	4	24	24	37.77	2026-07-27
5958	1717	3	12	12	26.74	2026-07-27
5959	1717	24	24	24	36.72	2026-07-27
5960	1718	7	6	6	151.96	2026-07-27
5961	1718	8	12	0	47.32	\N
5962	1718	12	48	48	138.3	2026-07-27
5963	1718	4	12	12	35.88	2026-07-27
5964	1718	31	24	24	142.92	2026-07-27
5965	1719	2	12	12	104.33	2026-07-28
5966	1719	13	12	12	97.54	2026-07-28
5967	1719	40	6	6	38.67	2026-07-28
5968	1719	22	6	6	165.43	2026-07-28
5969	1720	8	6	6	48.81	2026-07-28
5970	1720	4	12	12	37.01	2026-07-28
5971	1721	5	24	24	111.03	2026-07-28
5972	1721	17	6	6	53.01	2026-07-28
5973	1722	4	12	12	37.77	2026-07-31
5974	1722	26	6	0	55.53	\N
5975	1722	2	18	12	104.33	2026-07-31
5976	1722	15	24	24	170.21	2026-07-31
5977	1723	31	72	72	150.44	2026-07-28
5978	1723	3	24	24	26.74	2026-07-28
5979	1723	26	12	12	55.53	2026-07-28
5980	1723	8	6	0	49.81	\N
5981	1723	15	24	24	170.21	2026-07-28
5982	1724	13	24	24	92.66	2026-07-29
5983	1724	9	48	48	123.4	2026-07-29
5984	1724	10	24	24	71.16	2026-07-29
5985	1724	39	18	18	30.89	2026-07-29
5986	1724	20	6	6	65.18	2026-07-29
5987	1725	18	72	72	78.69	2026-07-29
5988	1725	17	6	6	50.36	2026-07-29
5989	1725	6	48	48	146.84	2026-07-29
5990	1725	3	12	12	25.4	2026-07-29
5991	1726	2	12	12	104.33	2026-07-29
5992	1726	6	72	72	154.57	2026-07-29
5993	1726	1	18	18	12.49	2026-07-29
5994	1726	16	12	0	161.56	\N
5995	1727	5	24	24	111.03	2026-07-29
5996	1727	24	48	48	36.72	2026-07-29
5997	1727	34	24	24	134.91	2026-07-29
5998	1728	33	12	12	111.42	2026-07-29
5999	1728	8	18	18	47.32	2026-07-29
6000	1728	9	48	48	123.4	2026-07-29
6001	1729	16	36	36	153.48	2026-07-29
6002	1729	2	18	18	99.11	2026-07-29
6003	1729	4	36	36	35.88	2026-07-29
6004	1729	3	12	12	25.4	2026-07-29
6005	1730	6	48	48	146.84	2026-07-30
6006	1730	4	12	12	35.88	2026-07-30
6007	1731	4	12	12	37.01	2026-07-30
6008	1731	2	12	7	102.24	2026-07-30
6009	1731	6	48	48	151.48	2026-07-30
6010	1732	17	6	6	51.95	2026-07-30
6011	1732	2	18	0	102.24	\N
6012	1732	5	24	24	108.81	2026-07-30
6013	1732	13	36	26	95.59	2026-07-30
6014	1732	1	12	12	12.24	2026-07-30
6015	1733	1	12	12	12.49	2026-07-30
6016	1733	33	12	12	117.28	2026-07-30
6017	1734	33	6	6	111.42	2026-07-31
6018	1734	3	36	12	25.4	2026-07-31
6019	1734	4	36	36	35.88	2026-07-31
6020	1734	2	6	0	99.11	\N
6021	1734	26	18	0	52.75	\N
6022	1735	37	24	24	123.09	2026-07-31
6023	1735	27	36	36	16.38	2026-07-31
6024	1735	4	24	12	35.88	2026-07-31
6025	1736	31	24	24	147.43	2026-07-31
6026	1736	4	24	0	37.01	\N
6027	1737	1	18	18	11.87	2026-07-30
6028	1737	7	6	1	151.96	2026-07-30
6029	1737	3	24	24	25.4	2026-07-30
6030	1738	31	48	48	150.44	2026-07-31
6031	1738	29	6	6	47.33	2026-07-31
6032	1738	12	72	72	145.58	2026-07-31
6033	1739	11	6	6	195.04	2026-07-31
6034	1739	8	6	6	49.81	2026-07-31
6035	1740	16	12	0	161.56	\N
6036	1740	4	24	24	37.77	2026-07-31
6037	1740	24	24	24	36.72	2026-07-31
6038	1740	2	18	0	104.33	\N
6039	1741	31	72	72	150.44	2026-07-31
6040	1741	16	36	36	161.56	2026-07-31
6041	1742	33	12	12	117.28	2026-07-31
6042	1742	12	24	24	145.58	2026-07-31
6043	1742	38	12	12	155.44	2026-07-31
6044	1743	15	36	36	170.21	2026-07-31
6045	1743	16	12	12	161.56	2026-07-31
6046	1743	37	24	24	129.57	2026-07-31
6047	1743	12	24	24	145.58	2026-07-31
6048	1744	4	12	12	37.77	2026-07-31
6049	1744	40	6	6	38.67	2026-07-31
6050	1745	2	18	18	104.33	2026-07-31
6051	1745	37	24	24	129.57	2026-07-31
6052	1745	16	36	36	161.56	2026-07-31
6053	1746	35	36	36	125.1	2026-07-31
6054	1746	38	12	12	155.44	2026-07-31
6055	1747	4	24	24	35.88	2026-07-31
6056	1747	15	36	36	161.7	2026-07-31
6057	1747	2	6	6	99.11	2026-07-31
6058	1747	31	48	48	142.92	2026-07-31
6059	1747	24	48	48	34.88	2026-07-31
6060	1748	11	12	12	195.04	2026-07-31
6061	1748	1	6	6	12.49	2026-07-31
6062	1748	4	24	24	37.77	2026-07-31
6063	1748	15	12	12	170.21	2026-07-31
6064	1749	9	72	72	123.4	2026-07-31
6065	1749	25	6	6	162.54	2026-07-31
6066	1749	1	6	6	11.87	2026-07-31
6067	1749	4	12	12	35.88	2026-07-31
\.
COPY purchase_orders (po_id, supplier_id, dc_id, order_date, promised_date, status) FROM stdin;
1	2	2	2025-11-03	2025-11-10	received
2	1	2	2025-11-05	2025-11-19	received
3	4	1	2025-11-05	2025-11-26	received
4	6	1	2025-11-06	2025-11-16	received
5	4	1	2025-11-06	2025-11-16	received
6	8	1	2025-11-07	2025-11-17	received
7	6	2	2025-11-07	2025-11-21	received
8	4	1	2025-11-07	2025-11-17	received
9	5	1	2025-11-07	2025-12-05	received
10	1	3	2025-11-10	2025-11-24	received
11	7	2	2025-11-10	2025-11-24	received
12	2	1	2025-11-10	2025-11-17	received
13	4	1	2025-11-11	2025-11-25	received
14	9	1	2025-11-11	2025-12-02	received
15	11	1	2025-11-11	2025-11-25	received
16	7	1	2025-11-12	2025-11-26	received
17	6	3	2025-11-13	2025-11-27	received
18	4	1	2025-11-13	2025-12-11	received
19	6	3	2025-11-14	2025-11-24	received
20	6	2	2025-11-14	2025-11-28	received
21	1	2	2025-11-14	2025-11-28	received
22	1	3	2025-11-14	2025-11-24	received
23	4	3	2025-11-14	2025-11-28	received
24	12	2	2025-11-14	2025-12-12	received
25	7	2	2025-11-14	2025-11-28	received
26	3	2	2025-11-14	2025-11-28	received
27	6	1	2025-11-17	2025-12-01	received
28	12	2	2025-11-17	2025-12-15	received
29	12	3	2025-11-17	2025-12-15	received
30	7	3	2025-11-17	2025-12-01	received
31	5	3	2025-11-17	2025-12-15	received
32	3	1	2025-11-17	2025-12-01	received
33	8	3	2025-11-18	2025-11-28	received
34	1	2	2025-11-18	2025-12-09	received
35	4	2	2025-11-18	2025-12-16	received
36	2	2	2025-11-18	2025-11-25	received
37	5	3	2025-11-18	2025-12-02	received
38	11	3	2025-11-18	2025-12-02	received
39	8	2	2025-11-19	2025-12-17	received
40	12	1	2025-11-19	2025-12-17	received
41	2	2	2025-11-19	2025-11-26	received
42	5	1	2025-11-19	2025-12-17	received
43	5	2	2025-11-19	2025-12-17	received
44	5	3	2025-11-19	2025-12-17	received
45	8	3	2025-11-20	2025-12-18	received
46	1	3	2025-11-20	2025-12-04	received
47	4	2	2025-11-20	2025-12-04	received
48	12	3	2025-11-20	2025-12-11	received
49	5	1	2025-11-20	2025-11-30	received
50	5	2	2025-11-20	2025-11-30	received
51	5	3	2025-11-20	2025-11-30	received
52	10	1	2025-11-20	2025-12-11	received
53	10	2	2025-11-20	2025-12-11	received
54	10	3	2025-11-20	2025-12-11	received
55	11	3	2025-11-20	2025-12-04	received
56	11	2	2025-11-20	2025-12-04	received
57	9	2	2025-11-21	2025-12-12	received
58	12	1	2025-11-21	2025-12-12	received
59	12	2	2025-11-21	2025-12-12	received
60	4	3	2025-11-21	2025-12-01	received
61	5	2	2025-11-21	2025-12-19	received
62	5	1	2025-11-21	2025-12-05	received
63	4	2	2025-11-21	2025-12-01	received
64	9	3	2025-11-22	2025-12-13	received
65	1	1	2025-11-23	2025-12-14	received
66	4	2	2025-11-23	2025-12-14	received
67	6	1	2025-11-24	2025-12-08	partial
68	1	2	2025-11-24	2025-12-04	received
69	1	1	2025-11-24	2025-12-04	received
70	2	1	2025-11-24	2025-12-01	received
71	4	3	2025-11-24	2025-12-08	partial
72	3	3	2025-11-24	2025-12-08	received
73	6	2	2025-11-25	2025-12-05	received
74	6	3	2025-11-25	2025-12-09	received
75	1	3	2025-11-25	2025-12-05	received
76	9	1	2025-11-25	2025-12-05	received
77	2	3	2025-11-25	2025-12-02	received
78	5	1	2025-11-25	2025-12-05	received
79	6	3	2025-11-26	2025-12-10	received
80	9	2	2025-11-26	2025-12-17	received
81	4	1	2025-11-26	2025-12-10	received
82	11	2	2025-11-26	2025-12-10	received
83	8	2	2025-11-27	2025-12-07	received
84	2	1	2025-11-27	2025-12-04	received
85	1	2	2025-11-28	2025-12-19	partial
86	4	3	2025-11-28	2025-12-26	received
87	3	2	2025-11-28	2025-12-19	received
88	6	1	2025-11-29	2025-12-09	received
89	11	1	2025-11-29	2025-12-13	received
90	3	1	2025-11-29	2025-12-13	received
91	3	2	2025-11-29	2025-12-13	received
92	3	3	2025-11-29	2025-12-20	received
93	4	3	2025-12-02	2025-12-16	received
94	1	3	2025-12-03	2025-12-24	received
95	2	3	2025-12-03	2025-12-10	received
96	5	2	2025-12-03	2025-12-13	received
97	6	1	2025-12-04	2025-12-18	received
98	1	1	2025-12-04	2025-12-18	received
99	12	2	2025-12-04	2026-01-01	received
100	2	2	2025-12-04	2025-12-11	received
101	7	2	2025-12-04	2025-12-18	received
102	10	1	2025-12-04	2026-01-01	received
103	10	2	2025-12-04	2026-01-01	received
104	10	3	2025-12-04	2026-01-01	received
105	5	1	2025-12-04	2026-01-01	received
106	6	2	2025-12-05	2025-12-15	received
107	12	3	2025-12-05	2026-01-02	received
108	7	3	2025-12-05	2025-12-19	received
109	10	1	2025-12-05	2025-12-19	received
110	10	2	2025-12-05	2025-12-19	received
111	10	3	2025-12-05	2025-12-19	received
112	3	1	2025-12-05	2025-12-26	received
113	4	2	2025-12-06	2025-12-20	received
114	3	3	2025-12-07	2025-12-21	received
115	8	2	2025-12-08	2026-01-05	received
116	4	1	2025-12-08	2026-01-05	received
117	7	1	2025-12-08	2025-12-22	received
118	2	3	2025-12-08	2025-12-15	received
119	2	1	2025-12-08	2025-12-15	received
120	5	3	2025-12-08	2025-12-22	received
121	3	3	2025-12-08	2025-12-22	received
122	6	1	2025-12-09	2025-12-23	received
123	6	2	2025-12-09	2025-12-23	received
124	4	1	2025-12-09	2025-12-19	received
125	4	2	2025-12-09	2025-12-23	received
126	8	1	2025-12-10	2026-01-07	received
127	9	3	2025-12-10	2025-12-20	received
128	12	1	2025-12-10	2026-01-07	partial
129	8	3	2025-12-12	2025-12-22	received
130	10	1	2025-12-12	2026-01-02	received
131	10	2	2025-12-12	2026-01-02	received
132	10	3	2025-12-12	2026-01-02	received
133	1	1	2025-12-13	2025-12-23	received
134	9	1	2025-12-13	2026-01-03	received
135	4	3	2025-12-13	2025-12-27	received
136	5	3	2025-12-14	2025-12-24	received
137	6	3	2025-12-15	2025-12-29	received
138	1	1	2025-12-15	2025-12-25	received
139	12	3	2025-12-15	2026-01-05	received
140	4	1	2025-12-15	2025-12-25	received
141	7	3	2025-12-15	2025-12-29	received
142	5	1	2025-12-15	2025-12-25	received
143	5	2	2025-12-15	2025-12-29	received
144	5	3	2025-12-15	2025-12-25	received
145	3	2	2025-12-15	2025-12-29	received
146	8	1	2025-12-16	2025-12-26	received
147	4	3	2025-12-16	2026-01-06	received
148	6	3	2025-12-17	2025-12-27	received
149	6	1	2025-12-17	2025-12-31	received
150	1	2	2025-12-17	2026-01-07	received
151	1	3	2025-12-17	2025-12-31	received
152	4	3	2025-12-17	2026-01-14	received
153	12	3	2025-12-17	2026-01-14	received
154	3	2	2025-12-17	2025-12-31	received
155	4	2	2025-12-17	2025-12-27	received
156	1	3	2025-12-18	2026-01-01	received
157	2	2	2025-12-18	2025-12-25	received
158	5	1	2025-12-18	2026-01-15	received
159	5	2	2025-12-18	2026-01-15	received
160	5	3	2025-12-18	2026-01-15	received
161	1	1	2025-12-19	2026-01-02	received
162	1	2	2025-12-19	2026-01-02	received
163	9	2	2025-12-19	2025-12-29	received
164	11	3	2025-12-19	2026-01-02	received
165	12	2	2025-12-20	2026-01-17	received
166	12	1	2025-12-21	2026-01-18	received
167	6	1	2025-12-22	2026-01-05	received
168	4	2	2025-12-22	2026-01-12	received
169	4	1	2025-12-22	2026-01-05	received
170	7	1	2025-12-22	2026-01-05	received
171	5	1	2025-12-22	2026-01-19	received
172	1	1	2025-12-23	2026-01-13	received
173	4	3	2025-12-23	2026-01-06	received
174	8	2	2025-12-24	2026-01-03	received
175	6	2	2025-12-24	2026-01-07	received
176	1	2	2025-12-24	2026-01-03	received
177	1	1	2025-12-24	2026-01-03	received
178	4	2	2025-12-24	2026-01-21	received
179	12	2	2025-12-24	2026-01-21	received
180	2	2	2025-12-24	2025-12-31	received
181	10	1	2025-12-24	2026-01-07	received
182	10	2	2025-12-24	2026-01-07	received
183	10	3	2025-12-24	2026-01-07	received
184	11	1	2025-12-24	2026-01-07	received
185	3	2	2025-12-25	2026-01-15	received
186	1	3	2025-12-26	2026-01-05	received
187	4	1	2025-12-27	2026-01-17	received
188	12	1	2025-12-27	2026-01-17	received
189	9	2	2025-12-29	2026-01-08	received
190	5	3	2025-12-29	2026-01-26	received
191	1	3	2025-12-30	2026-01-13	received
192	12	3	2025-12-30	2026-01-27	received
193	3	3	2025-12-30	2026-01-20	received
194	6	3	2025-12-31	2026-01-14	received
195	4	3	2025-12-31	2026-01-14	received
196	12	2	2025-12-31	2026-01-21	received
197	5	3	2025-12-31	2026-01-14	received
198	1	3	2026-01-01	2026-01-11	received
199	4	3	2026-01-01	2026-01-15	received
200	2	1	2026-01-01	2026-01-08	received
201	10	1	2026-01-01	2026-01-29	partial
202	10	2	2026-01-01	2026-01-29	received
203	10	3	2026-01-01	2026-01-29	received
204	1	3	2026-01-02	2026-01-16	received
205	1	1	2026-01-02	2026-01-12	received
206	9	3	2026-01-02	2026-01-12	received
207	4	1	2026-01-02	2026-01-12	received
208	5	1	2026-01-02	2026-01-12	received
209	8	2	2026-01-04	2026-02-01	received
210	1	3	2026-01-04	2026-01-25	received
211	1	2	2026-01-05	2026-01-26	received
212	9	3	2026-01-05	2026-01-26	received
213	7	2	2026-01-05	2026-01-19	received
214	2	2	2026-01-05	2026-01-12	received
215	8	3	2026-01-07	2026-01-17	received
216	11	2	2026-01-07	2026-01-21	received
217	4	1	2026-01-07	2026-01-17	received
218	3	1	2026-01-07	2026-01-21	received
219	6	2	2026-01-08	2026-01-18	received
220	1	3	2026-01-08	2026-01-18	received
221	9	1	2026-01-08	2026-01-18	received
222	12	1	2026-01-08	2026-02-05	received
223	2	3	2026-01-08	2026-01-15	received
224	5	1	2026-01-08	2026-01-22	received
225	1	1	2026-01-09	2026-01-23	received
226	7	1	2026-01-09	2026-01-23	received
227	2	1	2026-01-09	2026-01-16	received
228	2	3	2026-01-10	2026-01-17	received
229	8	1	2026-01-12	2026-01-22	received
230	9	2	2026-01-12	2026-02-02	received
231	4	3	2026-01-12	2026-01-22	received
232	12	3	2026-01-12	2026-02-09	received
233	7	2	2026-01-12	2026-01-26	received
234	7	3	2026-01-12	2026-01-26	received
235	3	1	2026-01-12	2026-01-26	received
236	3	2	2026-01-12	2026-01-26	received
237	4	1	2026-01-12	2026-01-26	received
238	6	2	2026-01-13	2026-01-27	received
239	12	2	2026-01-13	2026-02-10	received
240	7	2	2026-01-13	2026-01-27	received
241	5	2	2026-01-13	2026-02-10	received
242	4	2	2026-01-13	2026-01-23	received
243	3	2	2026-01-13	2026-02-03	received
244	1	2	2026-01-14	2026-01-28	received
245	1	1	2026-01-14	2026-02-04	received
246	3	2	2026-01-14	2026-01-28	received
247	3	3	2026-01-14	2026-01-28	received
248	9	2	2026-01-15	2026-01-25	received
249	10	1	2026-01-15	2026-02-05	received
250	10	2	2026-01-15	2026-02-05	received
251	10	3	2026-01-15	2026-02-05	received
252	4	2	2026-01-17	2026-01-31	received
253	4	1	2026-01-18	2026-02-01	received
254	8	1	2026-01-19	2026-02-16	received
255	8	3	2026-01-19	2026-02-16	received
256	8	2	2026-01-19	2026-01-29	received
257	1	1	2026-01-19	2026-01-29	received
258	12	3	2026-01-19	2026-02-16	received
259	5	1	2026-01-19	2026-02-16	received
260	5	2	2026-01-19	2026-02-16	received
261	5	3	2026-01-19	2026-02-16	received
262	7	1	2026-01-20	2026-02-03	received
263	5	1	2026-01-20	2026-01-30	received
264	5	2	2026-01-20	2026-01-30	received
265	5	3	2026-01-20	2026-01-30	received
266	12	3	2026-01-21	2026-02-11	received
267	4	2	2026-01-21	2026-01-31	received
268	7	3	2026-01-21	2026-02-04	received
269	10	1	2026-01-21	2026-02-04	received
270	10	2	2026-01-21	2026-02-04	received
271	10	3	2026-01-21	2026-02-04	received
272	5	3	2026-01-21	2026-02-04	received
273	4	3	2026-01-21	2026-02-04	received
274	4	2	2026-01-22	2026-02-05	received
275	3	2	2026-01-22	2026-02-05	received
276	6	1	2026-01-23	2026-02-02	partial
277	2	1	2026-01-23	2026-01-30	received
278	3	1	2026-01-23	2026-02-13	received
279	6	1	2026-01-24	2026-02-07	received
280	11	3	2026-01-24	2026-02-07	received
281	6	3	2026-01-25	2026-02-08	received
282	1	2	2026-01-25	2026-02-04	received
283	1	3	2026-01-25	2026-02-04	received
284	12	2	2026-01-25	2026-02-15	received
285	12	1	2026-01-25	2026-02-22	received
286	11	3	2026-01-25	2026-02-08	received
287	6	3	2026-01-26	2026-02-05	received
288	1	3	2026-01-26	2026-02-09	received
289	1	2	2026-01-26	2026-02-05	received
290	4	1	2026-01-26	2026-02-23	received
291	12	1	2026-01-26	2026-02-16	received
292	2	3	2026-01-26	2026-02-02	received
293	9	3	2026-01-27	2026-02-06	received
294	9	1	2026-01-27	2026-02-17	received
295	4	3	2026-01-28	2026-02-25	received
296	7	1	2026-01-28	2026-02-11	received
297	11	1	2026-01-28	2026-02-11	received
298	3	1	2026-01-29	2026-02-12	received
299	8	2	2026-01-30	2026-02-09	received
300	1	3	2026-01-30	2026-02-13	received
301	2	2	2026-01-30	2026-02-06	received
302	5	2	2026-01-30	2026-02-27	received
303	5	1	2026-01-31	2026-02-10	received
304	1	2	2026-02-01	2026-02-15	received
305	4	2	2026-02-01	2026-02-22	received
306	9	1	2026-02-02	2026-02-12	received
307	4	3	2026-02-02	2026-02-23	received
308	2	1	2026-02-02	2026-02-09	received
309	3	1	2026-02-02	2026-02-16	received
310	3	2	2026-02-02	2026-02-16	received
311	3	3	2026-02-02	2026-02-16	received
312	8	3	2026-02-03	2026-02-13	received
313	9	2	2026-02-03	2026-02-13	received
314	5	1	2026-02-03	2026-02-17	received
315	5	2	2026-02-03	2026-02-17	received
316	1	1	2026-02-04	2026-02-18	received
317	4	1	2026-02-05	2026-02-26	received
318	4	3	2026-02-06	2026-03-06	received
319	3	3	2026-02-06	2026-02-27	received
320	2	3	2026-02-07	2026-02-14	received
321	5	3	2026-02-07	2026-03-07	partial
322	6	2	2026-02-08	2026-02-22	received
323	7	3	2026-02-08	2026-02-22	received
324	6	2	2026-02-09	2026-02-19	received
325	8	2	2026-02-09	2026-03-09	received
326	8	3	2026-02-09	2026-03-09	received
327	1	3	2026-02-09	2026-02-19	received
328	12	2	2026-02-09	2026-03-09	received
329	12	3	2026-02-09	2026-03-09	received
330	4	2	2026-02-09	2026-02-19	received
331	1	1	2026-02-10	2026-03-03	received
332	6	1	2026-02-11	2026-02-21	received
333	8	1	2026-02-11	2026-03-11	received
334	1	1	2026-02-11	2026-02-21	received
335	4	1	2026-02-11	2026-02-25	received
336	2	2	2026-02-11	2026-02-18	received
337	4	1	2026-02-12	2026-03-12	received
338	9	3	2026-02-12	2026-03-05	received
339	12	2	2026-02-12	2026-03-12	received
340	2	1	2026-02-12	2026-02-19	received
341	10	1	2026-02-12	2026-03-12	received
342	10	2	2026-02-12	2026-03-12	received
343	10	3	2026-02-12	2026-03-12	received
344	6	3	2026-02-13	2026-02-27	received
345	4	2	2026-02-13	2026-03-13	received
346	2	2	2026-02-13	2026-02-20	received
347	5	1	2026-02-13	2026-03-13	received
348	5	2	2026-02-13	2026-03-13	received
349	5	3	2026-02-13	2026-03-13	received
350	3	2	2026-02-13	2026-02-27	received
351	6	1	2026-02-14	2026-02-28	received
352	1	1	2026-02-14	2026-02-28	received
353	3	1	2026-02-14	2026-02-28	received
354	1	3	2026-02-15	2026-03-01	received
355	1	3	2026-02-16	2026-02-26	received
356	10	1	2026-02-16	2026-03-02	received
357	10	2	2026-02-16	2026-03-02	received
358	10	3	2026-02-16	2026-03-02	received
359	11	3	2026-02-16	2026-03-02	received
360	3	3	2026-02-16	2026-03-02	received
361	4	2	2026-02-17	2026-03-03	partial
362	3	1	2026-02-17	2026-03-10	received
363	4	2	2026-02-18	2026-03-04	received
364	10	1	2026-02-18	2026-03-11	received
365	10	2	2026-02-18	2026-03-11	received
366	10	3	2026-02-18	2026-03-11	received
367	9	3	2026-02-19	2026-03-01	received
368	12	1	2026-02-19	2026-03-19	received
369	7	2	2026-02-19	2026-03-05	received
370	11	2	2026-02-19	2026-03-05	received
371	5	3	2026-02-19	2026-03-01	received
372	6	2	2026-02-20	2026-03-06	received
373	12	1	2026-02-20	2026-03-13	received
374	12	2	2026-02-20	2026-03-13	received
375	7	2	2026-02-22	2026-03-08	received
376	5	2	2026-02-22	2026-03-04	received
377	1	2	2026-02-23	2026-03-09	received
378	4	3	2026-02-23	2026-03-16	received
379	2	1	2026-02-23	2026-03-02	received
380	7	1	2026-02-23	2026-03-09	received
381	5	1	2026-02-24	2026-03-06	received
382	5	2	2026-02-24	2026-03-06	received
383	5	3	2026-02-24	2026-03-06	received
384	4	1	2026-02-24	2026-03-10	received
385	1	2	2026-02-25	2026-03-18	received
386	9	2	2026-02-25	2026-03-18	received
387	1	1	2026-02-26	2026-03-12	received
388	4	1	2026-02-26	2026-03-08	received
389	5	2	2026-02-26	2026-03-26	received
390	11	1	2026-02-26	2026-03-12	received
391	5	1	2026-02-26	2026-03-08	received
392	1	3	2026-02-27	2026-03-20	received
393	5	1	2026-02-27	2026-03-27	received
394	6	1	2026-03-02	2026-03-16	received
395	1	2	2026-03-02	2026-03-16	received
396	4	1	2026-03-02	2026-03-30	partial
397	4	3	2026-03-02	2026-03-16	received
398	5	3	2026-03-02	2026-03-16	received
399	6	3	2026-03-03	2026-03-13	received
400	6	2	2026-03-03	2026-03-17	received
401	9	2	2026-03-03	2026-03-13	received
402	1	1	2026-03-04	2026-03-25	received
403	4	2	2026-03-04	2026-04-01	received
404	11	3	2026-03-04	2026-03-18	received
405	1	3	2026-03-05	2026-03-19	received
406	4	1	2026-03-05	2026-03-26	received
407	12	3	2026-03-05	2026-03-26	received
408	7	3	2026-03-05	2026-03-19	received
409	5	2	2026-03-05	2026-03-15	received
410	3	1	2026-03-05	2026-03-26	received
411	8	3	2026-03-06	2026-03-16	received
412	4	3	2026-03-06	2026-03-20	received
413	4	2	2026-03-06	2026-03-20	partial
414	2	3	2026-03-06	2026-03-13	received
415	3	2	2026-03-06	2026-03-27	received
416	8	2	2026-03-07	2026-04-04	received
417	4	1	2026-03-07	2026-03-21	received
418	5	3	2026-03-07	2026-04-04	received
419	4	3	2026-03-07	2026-03-17	received
420	6	1	2026-03-08	2026-03-18	received
421	9	1	2026-03-08	2026-03-18	received
422	9	3	2026-03-08	2026-03-29	received
423	12	3	2026-03-08	2026-04-05	received
424	4	3	2026-03-08	2026-03-22	received
425	11	1	2026-03-08	2026-03-22	received
426	8	1	2026-03-09	2026-04-06	received
427	4	3	2026-03-09	2026-03-23	received
428	6	2	2026-03-10	2026-03-20	received
429	6	3	2026-03-10	2026-03-24	received
430	8	2	2026-03-10	2026-03-20	received
431	9	1	2026-03-10	2026-03-31	received
432	7	1	2026-03-10	2026-03-24	received
433	5	1	2026-03-10	2026-03-24	received
434	1	2	2026-03-11	2026-03-25	received
435	1	1	2026-03-11	2026-04-01	received
436	6	1	2026-03-12	2026-03-26	received
437	12	2	2026-03-12	2026-04-09	received
438	1	3	2026-03-13	2026-04-03	received
439	9	3	2026-03-13	2026-03-23	received
440	4	2	2026-03-13	2026-03-23	received
441	3	3	2026-03-13	2026-03-27	received
442	1	3	2026-03-14	2026-03-24	received
443	4	2	2026-03-14	2026-04-11	received
444	10	1	2026-03-15	2026-03-29	received
445	10	2	2026-03-15	2026-03-29	received
446	10	3	2026-03-15	2026-03-29	received
447	5	1	2026-03-15	2026-04-12	received
448	6	2	2026-03-16	2026-03-30	received
449	1	2	2026-03-16	2026-03-26	received
450	4	2	2026-03-16	2026-04-06	received
451	3	2	2026-03-16	2026-03-30	partial
452	3	1	2026-03-16	2026-03-30	received
453	8	3	2026-03-17	2026-04-14	received
454	1	3	2026-03-17	2026-03-31	received
455	4	1	2026-03-17	2026-04-14	received
456	4	3	2026-03-17	2026-04-14	received
457	2	3	2026-03-17	2026-03-24	received
458	3	3	2026-03-17	2026-04-07	received
459	9	1	2026-03-18	2026-04-08	received
460	4	3	2026-03-18	2026-04-08	received
461	2	3	2026-03-18	2026-03-25	received
462	8	3	2026-03-19	2026-03-29	received
463	1	1	2026-03-19	2026-04-02	received
464	5	3	2026-03-19	2026-04-02	received
465	6	3	2026-03-20	2026-04-03	received
466	1	3	2026-03-20	2026-04-03	received
467	4	1	2026-03-20	2026-04-10	received
468	12	1	2026-03-20	2026-04-10	received
469	7	3	2026-03-20	2026-04-03	received
470	5	3	2026-03-20	2026-04-17	received
471	5	2	2026-03-21	2026-04-18	received
472	4	1	2026-03-22	2026-04-01	received
473	6	1	2026-03-23	2026-04-06	received
474	1	1	2026-03-23	2026-04-02	received
475	12	1	2026-03-23	2026-04-20	received
476	2	2	2026-03-23	2026-03-30	received
477	7	3	2026-03-23	2026-04-06	received
478	2	1	2026-03-23	2026-03-30	received
479	10	1	2026-03-23	2026-04-20	received
480	10	2	2026-03-23	2026-04-20	received
481	10	3	2026-03-23	2026-04-20	received
482	8	1	2026-03-24	2026-04-03	received
483	1	3	2026-03-24	2026-04-07	received
484	12	3	2026-03-24	2026-04-21	received
485	4	1	2026-03-24	2026-04-07	received
486	11	3	2026-03-25	2026-04-08	received
487	5	1	2026-03-25	2026-04-04	received
488	6	2	2026-03-26	2026-04-05	received
489	1	2	2026-03-26	2026-04-05	received
490	1	3	2026-03-26	2026-04-05	received
491	2	1	2026-03-26	2026-04-02	received
492	2	2	2026-03-26	2026-04-02	received
493	3	2	2026-03-26	2026-04-16	received
494	1	3	2026-03-27	2026-04-06	received
495	4	3	2026-03-27	2026-04-10	received
496	9	1	2026-03-27	2026-04-06	received
497	12	3	2026-03-27	2026-04-17	received
498	3	3	2026-03-27	2026-04-10	received
499	11	1	2026-03-28	2026-04-11	received
500	3	1	2026-03-28	2026-04-11	partial
501	6	2	2026-03-29	2026-04-12	received
502	4	3	2026-03-29	2026-04-08	received
503	8	2	2026-03-30	2026-04-27	received
504	4	2	2026-03-30	2026-04-27	received
505	8	3	2026-03-31	2026-04-28	received
506	12	2	2026-03-31	2026-04-28	received
507	4	2	2026-03-31	2026-04-14	received
508	10	1	2026-03-31	2026-04-21	received
509	10	2	2026-03-31	2026-04-21	received
510	10	3	2026-03-31	2026-04-21	received
511	5	3	2026-03-31	2026-04-14	received
512	11	3	2026-03-31	2026-04-14	received
513	3	3	2026-03-31	2026-04-21	received
514	9	3	2026-04-01	2026-04-22	received
515	6	3	2026-04-02	2026-04-16	received
516	6	3	2026-04-03	2026-04-13	received
517	1	1	2026-04-03	2026-04-24	received
518	9	2	2026-04-03	2026-04-13	received
519	4	3	2026-04-03	2026-04-17	received
520	12	3	2026-04-03	2026-05-01	received
521	5	2	2026-04-03	2026-04-17	received
522	3	1	2026-04-03	2026-04-17	received
523	8	1	2026-04-05	2026-05-03	received
524	4	1	2026-04-05	2026-05-03	received
525	3	3	2026-04-06	2026-04-20	received
526	8	2	2026-04-07	2026-04-17	partial
527	8	3	2026-04-07	2026-04-17	received
528	6	2	2026-04-07	2026-04-21	received
529	1	2	2026-04-07	2026-04-28	received
530	7	2	2026-04-07	2026-04-21	received
531	2	2	2026-04-07	2026-04-14	received
532	5	1	2026-04-07	2026-04-17	received
533	5	2	2026-04-07	2026-04-17	received
534	5	3	2026-04-07	2026-04-17	received
535	4	2	2026-04-07	2026-04-21	received
536	9	3	2026-04-08	2026-04-18	received
537	4	1	2026-04-08	2026-04-29	received
538	2	3	2026-04-08	2026-04-15	received
539	1	2	2026-04-09	2026-04-23	received
540	7	2	2026-04-09	2026-04-23	received
541	5	1	2026-04-09	2026-05-07	received
542	6	3	2026-04-10	2026-04-24	received
543	4	3	2026-04-10	2026-05-08	received
544	9	3	2026-04-10	2026-05-01	received
545	11	2	2026-04-10	2026-04-24	received
546	8	1	2026-04-11	2026-04-21	received
547	1	1	2026-04-11	2026-04-25	received
548	7	1	2026-04-11	2026-04-25	received
549	1	3	2026-04-12	2026-05-03	received
550	7	3	2026-04-12	2026-04-26	received
551	6	1	2026-04-13	2026-04-27	received
552	5	3	2026-04-13	2026-04-23	received
553	3	2	2026-04-13	2026-04-27	received
554	4	2	2026-04-14	2026-04-24	received
555	5	1	2026-04-14	2026-05-12	received
556	5	2	2026-04-14	2026-05-12	received
557	5	3	2026-04-14	2026-05-12	received
558	8	1	2026-04-15	2026-05-13	received
559	2	1	2026-04-15	2026-04-22	received
560	11	3	2026-04-15	2026-04-29	received
561	3	1	2026-04-15	2026-04-29	received
562	1	2	2026-04-16	2026-04-30	partial
563	9	2	2026-04-16	2026-05-07	received
564	12	3	2026-04-16	2026-05-07	received
565	12	1	2026-04-16	2026-05-14	received
566	3	3	2026-04-16	2026-04-30	received
567	4	3	2026-04-17	2026-05-01	received
568	5	1	2026-04-19	2026-05-03	received
569	6	2	2026-04-20	2026-05-04	received
570	4	1	2026-04-20	2026-04-30	received
571	5	2	2026-04-20	2026-05-18	received
572	1	1	2026-04-21	2026-05-05	received
573	4	2	2026-04-21	2026-05-05	received
574	12	2	2026-04-21	2026-05-12	received
575	7	1	2026-04-21	2026-05-05	received
576	11	1	2026-04-21	2026-05-05	received
577	4	3	2026-04-21	2026-05-01	received
578	6	1	2026-04-22	2026-05-06	received
579	4	1	2026-04-22	2026-05-06	received
580	4	1	2026-04-23	2026-05-21	received
581	12	1	2026-04-23	2026-05-14	received
582	7	3	2026-04-23	2026-05-07	received
583	8	3	2026-04-24	2026-05-04	received
584	6	1	2026-04-24	2026-05-08	received
585	9	1	2026-04-24	2026-05-04	received
586	4	2	2026-04-24	2026-05-22	partial
587	4	3	2026-04-25	2026-05-16	received
588	6	1	2026-04-26	2026-05-06	received
589	2	1	2026-04-26	2026-05-03	received
590	4	1	2026-04-26	2026-05-06	received
591	9	1	2026-04-29	2026-05-20	received
592	12	2	2026-04-29	2026-05-27	received
593	2	2	2026-04-30	2026-05-07	received
594	8	3	2026-05-01	2026-05-29	received
595	6	2	2026-05-01	2026-05-15	received
596	8	2	2026-05-01	2026-05-11	received
597	1	3	2026-05-01	2026-05-22	received
598	4	2	2026-05-01	2026-05-22	received
599	3	3	2026-05-01	2026-05-22	received
600	11	3	2026-05-02	2026-05-16	received
601	6	3	2026-05-04	2026-05-18	received
602	1	3	2026-05-04	2026-05-14	received
603	9	2	2026-05-04	2026-05-25	received
604	1	2	2026-05-05	2026-05-15	received
605	12	3	2026-05-05	2026-06-02	received
606	2	2	2026-05-05	2026-05-12	received
607	11	1	2026-05-05	2026-05-19	received
608	4	2	2026-05-05	2026-05-19	received
609	6	3	2026-05-06	2026-05-20	received
610	1	3	2026-05-06	2026-05-20	partial
611	1	2	2026-05-06	2026-05-16	partial
612	11	3	2026-05-06	2026-05-20	received
613	8	1	2026-05-07	2026-05-17	received
614	9	3	2026-05-07	2026-05-17	received
615	12	1	2026-05-07	2026-06-04	received
616	2	3	2026-05-07	2026-05-14	received
617	5	3	2026-05-07	2026-06-04	received
618	6	1	2026-05-08	2026-05-22	received
619	1	1	2026-05-08	2026-05-29	partial
620	2	3	2026-05-08	2026-05-15	received
621	5	1	2026-05-08	2026-06-05	received
622	3	2	2026-05-08	2026-05-22	received
623	3	3	2026-05-08	2026-05-22	received
624	4	1	2026-05-09	2026-05-30	received
625	3	1	2026-05-09	2026-05-23	received
626	6	3	2026-05-11	2026-05-21	received
627	8	2	2026-05-11	2026-06-08	received
628	4	3	2026-05-11	2026-05-25	received
629	9	3	2026-05-11	2026-06-01	received
630	11	2	2026-05-11	2026-05-25	received
631	3	3	2026-05-11	2026-05-25	received
632	6	1	2026-05-12	2026-05-22	received
633	1	1	2026-05-12	2026-05-22	received
634	4	1	2026-05-13	2026-05-27	received
635	4	2	2026-05-14	2026-05-24	received
636	10	1	2026-05-14	2026-06-11	received
637	10	2	2026-05-14	2026-06-11	received
638	10	3	2026-05-14	2026-06-11	received
639	6	2	2026-05-15	2026-05-25	received
640	4	1	2026-05-15	2026-06-12	received
641	4	3	2026-05-15	2026-06-12	received
642	12	3	2026-05-15	2026-06-05	received
643	2	1	2026-05-15	2026-05-22	received
644	5	1	2026-05-15	2026-05-29	received
645	3	3	2026-05-16	2026-06-06	received
646	6	2	2026-05-18	2026-06-01	received
647	1	2	2026-05-18	2026-06-08	partial
648	9	3	2026-05-18	2026-06-08	received
649	5	3	2026-05-18	2026-05-28	received
650	4	3	2026-05-18	2026-06-01	received
651	9	2	2026-05-19	2026-06-09	received
652	7	2	2026-05-19	2026-06-02	received
653	9	1	2026-05-20	2026-05-30	received
654	4	1	2026-05-20	2026-06-03	received
655	11	3	2026-05-20	2026-06-03	received
656	5	3	2026-05-20	2026-06-03	received
657	11	1	2026-05-20	2026-06-03	received
658	6	1	2026-05-21	2026-06-04	received
659	1	1	2026-05-21	2026-06-04	received
660	7	2	2026-05-21	2026-06-04	received
661	7	1	2026-05-21	2026-06-04	received
662	5	1	2026-05-21	2026-06-18	received
663	5	2	2026-05-21	2026-05-31	received
664	4	1	2026-05-21	2026-06-04	received
665	2	1	2026-05-22	2026-05-29	received
666	9	2	2026-05-23	2026-06-02	received
667	10	1	2026-05-23	2026-06-06	received
668	10	2	2026-05-23	2026-06-06	received
669	10	3	2026-05-23	2026-06-06	received
670	5	1	2026-05-23	2026-06-02	received
671	6	1	2026-05-25	2026-06-04	received
672	6	3	2026-05-25	2026-06-08	received
673	8	1	2026-05-25	2026-06-04	received
674	1	1	2026-05-25	2026-06-04	received
675	7	3	2026-05-25	2026-06-08	received
676	5	2	2026-05-25	2026-06-08	received
677	3	3	2026-05-25	2026-06-08	received
678	8	2	2026-05-26	2026-06-23	received
679	12	2	2026-05-26	2026-06-16	received
680	3	1	2026-05-26	2026-06-16	received
681	4	3	2026-05-27	2026-06-10	received
682	6	2	2026-05-29	2026-06-12	received
683	8	3	2026-05-29	2026-06-08	received
684	1	2	2026-05-29	2026-06-19	received
685	5	2	2026-05-29	2026-06-26	received
686	4	1	2026-05-29	2026-06-08	received
687	11	1	2026-05-30	2026-06-13	received
688	6	1	2026-05-31	2026-06-14	partial
689	8	3	2026-06-01	2026-06-29	received
690	4	1	2026-06-01	2026-06-29	received
691	5	3	2026-06-01	2026-06-29	received
692	6	3	2026-06-02	2026-06-12	received
693	8	1	2026-06-02	2026-06-30	received
694	1	3	2026-06-02	2026-06-16	received
695	4	1	2026-06-02	2026-06-16	received
696	6	3	2026-06-03	2026-06-17	received
697	1	2	2026-06-03	2026-06-17	received
698	4	2	2026-06-03	2026-07-01	received
699	2	3	2026-06-03	2026-06-10	received
700	8	2	2026-06-04	2026-06-14	received
701	1	3	2026-06-04	2026-06-14	partial
702	12	2	2026-06-04	2026-07-02	received
703	4	2	2026-06-04	2026-06-14	received
704	6	3	2026-06-05	2026-06-19	received
705	8	1	2026-06-05	2026-06-15	received
706	1	1	2026-06-05	2026-06-19	partial
707	1	3	2026-06-05	2026-06-19	partial
708	4	3	2026-06-05	2026-07-03	received
709	9	3	2026-06-06	2026-06-16	received
710	2	2	2026-06-06	2026-06-13	received
711	6	1	2026-06-07	2026-06-17	received
712	4	3	2026-06-07	2026-06-17	received
713	2	2	2026-06-07	2026-06-14	received
714	5	1	2026-06-07	2026-07-05	received
715	5	2	2026-06-07	2026-07-05	received
716	5	3	2026-06-07	2026-07-05	received
717	3	2	2026-06-07	2026-06-21	received
718	6	2	2026-06-08	2026-06-18	received
719	6	1	2026-06-08	2026-06-22	received
720	3	1	2026-06-08	2026-06-22	received
721	6	2	2026-06-10	2026-06-24	received
722	1	2	2026-06-10	2026-06-24	partial
723	4	2	2026-06-10	2026-07-08	received
724	4	3	2026-06-10	2026-07-01	received
725	11	2	2026-06-10	2026-06-24	received
726	8	2	2026-06-11	2026-07-09	received
727	6	1	2026-06-11	2026-06-25	received
728	9	2	2026-06-11	2026-06-21	received
729	12	1	2026-06-11	2026-07-02	received
730	5	3	2026-06-11	2026-06-25	received
731	8	3	2026-06-12	2026-07-10	received
732	9	2	2026-06-12	2026-07-03	received
733	10	1	2026-06-12	2026-07-03	received
734	10	2	2026-06-12	2026-07-03	received
735	10	3	2026-06-12	2026-07-03	received
736	11	3	2026-06-12	2026-06-26	received
737	6	3	2026-06-13	2026-06-23	received
738	4	1	2026-06-13	2026-06-27	received
739	2	1	2026-06-13	2026-06-20	received
740	1	1	2026-06-14	2026-07-05	received
741	4	1	2026-06-14	2026-06-28	received
742	6	3	2026-06-15	2026-06-29	received
743	4	3	2026-06-15	2026-06-29	received
744	8	2	2026-06-16	2026-06-26	received
745	8	3	2026-06-16	2026-06-26	received
746	12	1	2026-06-16	2026-07-14	received
747	2	2	2026-06-16	2026-06-23	received
748	6	2	2026-06-17	2026-07-01	received
749	1	2	2026-06-17	2026-06-27	received
750	1	3	2026-06-17	2026-06-27	received
751	1	1	2026-06-17	2026-06-27	received
752	4	3	2026-06-17	2026-07-15	received
753	7	3	2026-06-17	2026-07-01	received
754	5	1	2026-06-17	2026-07-15	received
755	4	2	2026-06-17	2026-07-01	received
756	8	1	2026-06-18	2026-07-16	partial
757	6	3	2026-06-18	2026-07-02	received
758	4	2	2026-06-18	2026-07-02	received
759	9	1	2026-06-18	2026-06-28	received
760	2	3	2026-06-18	2026-06-25	received
761	5	3	2026-06-18	2026-06-28	received
762	3	1	2026-06-18	2026-07-02	received
763	2	1	2026-06-19	2026-06-26	received
764	5	3	2026-06-19	2026-07-17	received
765	12	3	2026-06-22	2026-07-13	received
766	7	3	2026-06-22	2026-07-06	received
767	10	1	2026-06-22	2026-07-06	received
768	10	2	2026-06-22	2026-07-06	received
769	10	3	2026-06-22	2026-07-06	received
770	11	1	2026-06-22	2026-07-06	received
771	4	1	2026-06-23	2026-07-14	received
772	6	1	2026-06-24	2026-07-04	received
773	6	2	2026-06-24	2026-07-08	received
774	1	3	2026-06-24	2026-07-15	open
775	6	2	2026-06-25	2026-07-05	received
776	6	1	2026-06-25	2026-07-09	received
777	9	3	2026-06-25	2026-07-05	received
778	5	1	2026-06-25	2026-07-05	received
779	5	2	2026-06-25	2026-07-05	received
780	5	3	2026-06-25	2026-07-05	received
781	1	3	2026-06-26	2026-07-06	received
782	11	1	2026-06-26	2026-07-10	received
783	12	1	2026-06-27	2026-07-25	received
784	12	2	2026-06-27	2026-07-25	received
785	5	1	2026-06-27	2026-07-07	received
786	1	1	2026-06-28	2026-07-12	received
787	12	3	2026-06-28	2026-07-26	received
788	6	3	2026-06-29	2026-07-09	partial
789	8	3	2026-06-29	2026-07-09	received
790	6	1	2026-06-29	2026-07-13	received
791	1	3	2026-06-29	2026-07-13	open
792	9	2	2026-06-29	2026-07-20	received
793	5	2	2026-06-29	2026-07-27	received
794	11	3	2026-06-29	2026-07-13	received
795	3	3	2026-06-29	2026-07-13	received
796	4	2	2026-06-29	2026-07-09	received
797	4	3	2026-06-29	2026-07-13	received
798	8	2	2026-06-30	2026-07-10	received
799	9	1	2026-06-30	2026-07-21	received
800	4	2	2026-06-30	2026-07-21	received
801	11	2	2026-06-30	2026-07-14	received
802	3	3	2026-06-30	2026-07-21	received
803	6	1	2026-07-01	2026-07-11	received
804	8	2	2026-07-01	2026-07-29	received
805	6	3	2026-07-01	2026-07-15	received
806	1	2	2026-07-01	2026-07-22	open
807	9	2	2026-07-01	2026-07-11	received
808	5	1	2026-07-01	2026-07-29	open
809	5	3	2026-07-01	2026-07-15	received
810	8	3	2026-07-02	2026-07-30	received
811	5	2	2026-07-02	2026-07-16	received
812	3	2	2026-07-02	2026-07-16	received
813	6	2	2026-07-03	2026-07-17	received
814	6	3	2026-07-03	2026-07-17	received
815	8	1	2026-07-03	2026-07-13	received
816	4	1	2026-07-03	2026-07-31	open
817	4	2	2026-07-03	2026-07-17	received
818	7	3	2026-07-03	2026-07-17	received
819	11	2	2026-07-03	2026-07-17	received
820	6	1	2026-07-04	2026-07-18	received
821	3	1	2026-07-04	2026-07-18	received
822	1	1	2026-07-05	2026-07-19	partial
823	4	2	2026-07-05	2026-07-19	received
824	4	3	2026-07-05	2026-07-26	received
825	3	3	2026-07-05	2026-07-19	received
826	1	3	2026-07-06	2026-07-27	open
827	4	2	2026-07-07	2026-08-04	open
828	2	3	2026-07-07	2026-07-14	received
829	3	2	2026-07-07	2026-07-28	received
830	8	2	2026-07-08	2026-07-18	received
831	9	1	2026-07-08	2026-07-18	received
832	4	2	2026-07-08	2026-07-18	received
833	7	1	2026-07-08	2026-07-22	received
834	5	1	2026-07-08	2026-07-22	received
835	1	2	2026-07-09	2026-07-30	open
836	4	3	2026-07-09	2026-07-23	received
837	9	3	2026-07-09	2026-07-30	received
838	2	3	2026-07-09	2026-07-16	received
839	6	3	2026-07-10	2026-07-24	received
840	8	1	2026-07-10	2026-08-07	open
841	4	3	2026-07-10	2026-08-07	open
842	10	1	2026-07-10	2026-08-07	open
843	10	2	2026-07-10	2026-08-07	open
844	10	3	2026-07-10	2026-08-07	open
845	3	2	2026-07-10	2026-07-24	received
846	5	2	2026-07-11	2026-07-21	partial
847	6	2	2026-07-13	2026-07-23	received
848	7	1	2026-07-13	2026-07-27	received
849	2	1	2026-07-13	2026-07-20	open
850	8	3	2026-07-14	2026-07-24	received
851	9	3	2026-07-15	2026-07-25	received
852	7	3	2026-07-16	2026-07-30	open
853	3	3	2026-07-16	2026-07-30	open
854	8	2	2026-07-17	2026-08-14	open
855	12	2	2026-07-17	2026-08-14	open
856	3	1	2026-07-17	2026-08-07	open
857	1	2	2026-07-18	2026-08-01	open
858	7	2	2026-07-18	2026-08-01	received
859	6	1	2026-07-20	2026-08-03	partial
860	8	3	2026-07-20	2026-08-17	open
861	8	1	2026-07-20	2026-07-30	received
862	1	1	2026-07-20	2026-08-10	open
863	4	1	2026-07-20	2026-08-03	open
864	5	1	2026-07-20	2026-08-17	open
865	8	2	2026-07-21	2026-07-31	received
866	6	1	2026-07-21	2026-08-04	open
867	6	2	2026-07-21	2026-08-04	open
868	2	1	2026-07-21	2026-07-28	open
869	5	2	2026-07-21	2026-08-18	open
870	5	3	2026-07-21	2026-07-31	open
871	4	2	2026-07-21	2026-08-04	open
872	8	1	2026-07-22	2026-08-19	open
873	6	2	2026-07-22	2026-08-05	open
874	4	1	2026-07-22	2026-08-19	partial
875	12	1	2026-07-22	2026-08-19	open
876	5	1	2026-07-22	2026-08-01	received
877	4	2	2026-07-22	2026-08-01	received
878	4	2	2026-07-23	2026-08-13	open
879	4	3	2026-07-23	2026-08-13	open
880	12	3	2026-07-23	2026-08-20	open
881	1	3	2026-07-24	2026-08-07	open
882	9	2	2026-07-24	2026-08-14	open
883	7	2	2026-07-24	2026-08-07	open
884	11	3	2026-07-24	2026-08-07	open
885	11	3	2026-07-25	2026-08-08	open
886	12	2	2026-07-26	2026-08-16	open
887	6	2	2026-07-27	2026-08-06	open
888	6	3	2026-07-27	2026-08-10	open
889	1	1	2026-07-27	2026-08-10	open
890	1	3	2026-07-27	2026-08-10	open
891	5	3	2026-07-27	2026-08-10	open
892	6	3	2026-07-28	2026-08-11	open
893	1	3	2026-07-28	2026-08-07	open
894	12	3	2026-07-28	2026-08-25	open
895	5	3	2026-07-28	2026-08-25	open
896	6	1	2026-07-29	2026-08-08	open
897	12	3	2026-07-29	2026-08-19	open
898	11	1	2026-07-29	2026-08-12	open
899	6	3	2026-07-31	2026-08-10	open
900	8	3	2026-07-31	2026-08-10	open
901	9	1	2026-07-31	2026-08-10	open
\.
COPY purchase_order_lines (po_line_id, po_id, product_id, qty_ordered, qty_received, received_date) FROM stdin;
1	1	23	132	132	2025-11-21
2	2	7	36	36	2025-11-24
3	3	15	144	144	2025-11-27
4	4	1	48	48	2025-11-16
5	5	37	528	528	2025-11-16
6	6	4	180	180	2025-11-20
7	7	5	264	264	2025-11-21
8	8	17	54	54	2025-11-18
9	9	31	528	528	2025-12-05
10	10	7	24	24	2025-11-23
11	11	22	54	54	2025-11-25
12	12	25	72	72	2025-11-29
13	13	11	42	42	2025-11-25
14	14	14	84	84	2025-12-02
15	13	19	120	120	2025-11-30
16	15	34	48	48	2025-11-26
17	16	22	60	60	2025-11-25
18	17	5	264	264	2025-11-29
19	18	13	96	96	2025-12-14
20	19	1	48	48	2025-11-24
21	20	3	96	96	2025-11-26
22	21	6	336	336	2025-11-30
23	22	9	336	336	2025-11-22
24	21	10	96	96	2025-11-20
25	23	11	42	42	2025-11-28
26	24	18	216	216	2025-12-12
27	25	24	336	336	2025-11-27
28	26	38	180	180	2025-11-29
29	27	5	288	288	2025-11-29
30	28	20	66	66	2025-12-15
31	29	20	90	90	2025-12-17
32	30	24	312	312	2025-12-02
33	31	31	576	576	2025-12-17
34	32	38	252	252	2025-11-29
35	33	4	180	180	2025-11-29
36	34	8	54	54	2025-12-12
37	35	13	84	84	2025-12-18
38	36	25	72	72	2025-12-10
39	37	33	84	84	2025-12-04
40	38	34	72	72	2025-12-04
41	39	2	84	84	2025-12-15
42	40	20	78	78	2025-12-17
43	41	21	240	240	2025-12-10
44	42	29	72	72	2025-12-17
45	43	29	72	72	2025-12-14
46	44	29	72	72	2025-12-16
47	45	2	90	90	2025-12-19
48	46	6	360	360	2025-12-09
49	47	11	30	30	2025-12-04
50	48	16	276	276	2025-12-09
51	47	17	48	48	2025-11-25
52	49	27	132	132	2025-11-29
53	50	27	132	132	2025-11-26
54	51	27	132	132	2025-12-01
55	52	30	264	264	2025-12-10
56	53	30	264	264	2025-12-13
57	54	30	264	264	2025-12-12
58	55	32	42	42	2025-12-06
59	56	34	60	60	2025-12-03
60	47	39	90	90	2025-12-03
61	57	14	84	84	2025-12-13
62	58	16	300	300	2025-12-13
63	59	16	288	288	2025-12-12
64	60	17	60	60	2025-11-30
65	61	31	552	552	2025-12-18
66	62	33	84	84	2025-12-06
67	63	37	552	552	2025-11-30
68	64	14	84	84	2025-12-13
69	65	8	60	60	2025-12-12
70	66	15	120	120	2025-12-15
71	67	3	108	97	2025-12-09
72	68	9	312	312	2025-12-03
73	69	10	144	144	2025-11-30
74	70	21	192	192	2025-12-14
75	71	37	528	475	2025-12-04
76	72	38	180	180	2025-12-08
77	71	39	90	90	2025-12-11
78	73	1	48	48	2025-12-04
79	74	3	108	108	2025-12-13
80	75	10	120	120	2025-12-06
81	76	12	432	432	2025-12-03
82	77	21	192	192	2025-12-18
83	78	35	84	84	2025-12-04
84	79	5	264	264	2025-12-08
85	80	14	72	72	2025-12-16
86	81	19	144	144	2025-12-09
87	82	32	30	30	2025-12-09
88	83	4	180	180	2025-12-03
89	84	23	120	120	2025-12-20
90	85	8	60	54	2025-12-18
91	86	13	108	108	2025-12-25
92	87	38	168	168	2025-12-11
93	87	40	66	66	2025-12-19
94	88	1	66	66	2025-12-07
95	89	32	36	36	2025-12-14
96	90	36	168	168	2025-12-12
97	91	36	144	144	2025-12-12
98	92	40	66	66	2025-12-21
99	93	19	144	144	2025-12-15
100	94	8	60	60	2025-12-23
101	95	25	90	90	2025-12-23
102	96	35	84	84	2025-12-14
103	97	5	264	264	2025-12-12
104	98	7	30	30	2025-12-15
105	99	20	72	72	2026-01-02
106	100	23	156	156	2025-12-27
107	101	24	336	336	2025-12-19
108	102	26	108	108	2026-01-02
109	103	26	108	108	2025-12-30
110	104	26	108	108	2026-01-01
111	105	31	528	528	2026-01-01
112	106	1	42	42	2025-12-12
113	107	20	78	78	2025-12-31
114	108	24	312	312	2025-12-19
115	109	28	48	48	2025-12-18
116	110	28	48	48	2025-12-19
117	111	28	48	48	2025-12-19
118	112	40	48	48	2025-12-27
119	113	19	144	144	2025-12-21
120	114	36	168	168	2025-12-21
121	115	2	84	84	2026-01-04
122	116	13	96	96	2026-01-04
123	117	22	66	66	2025-12-23
124	118	23	132	132	2026-01-01
125	119	25	72	72	2025-12-28
126	120	33	90	90	2025-12-24
127	121	38	180	180	2025-12-24
128	116	39	96	96	2025-12-23
129	122	3	84	84	2025-12-23
130	123	5	288	288	2025-12-24
131	124	37	528	528	2025-12-18
132	125	39	90	90	2025-12-17
133	126	2	96	96	2026-01-03
134	127	12	432	432	2025-12-20
135	128	18	240	216	2026-01-08
136	129	4	168	168	2025-12-23
137	130	30	264	264	2026-01-04
138	131	30	264	264	2026-01-03
139	132	30	264	264	2026-01-03
140	133	10	120	120	2025-12-23
141	134	14	84	84	2026-01-06
142	135	19	144	144	2025-12-26
143	136	35	72	72	2025-12-21
144	137	3	96	96	2025-12-30
145	138	9	312	312	2025-12-29
146	139	16	276	276	2026-01-03
147	140	17	60	60	2025-12-28
148	141	22	60	60	2025-12-28
149	142	27	132	132	2025-12-24
150	143	27	132	132	2025-12-27
151	144	27	132	132	2025-12-26
152	143	33	90	90	2025-12-27
153	145	38	192	192	2025-12-30
154	146	4	168	168	2025-12-28
155	147	15	120	120	2026-01-07
156	148	1	54	54	2025-12-27
157	149	5	264	264	2026-01-03
158	150	7	36	36	2026-01-01
159	151	7	24	24	2026-01-01
160	150	8	48	48	2026-01-06
161	152	13	96	96	2026-01-14
162	153	18	216	216	2026-01-12
163	154	36	144	144	2025-12-29
164	155	37	552	552	2025-12-27
165	156	6	336	336	2026-01-02
166	157	25	72	72	2026-01-10
167	158	29	72	72	2026-01-18
168	159	29	72	72	2026-01-15
169	160	29	72	72	2026-01-14
170	161	6	336	336	2026-01-06
171	162	6	336	336	2026-01-04
172	162	10	144	144	2025-12-28
173	163	12	432	432	2025-12-26
174	164	32	42	42	2025-12-31
175	165	20	66	66	2026-01-15
176	166	20	78	78	2026-01-16
177	167	1	48	48	2026-01-04
178	167	3	108	108	2026-01-01
179	168	15	120	120	2026-01-12
180	169	19	168	168	2026-01-06
181	170	24	336	336	2026-01-05
182	171	31	528	528	2026-01-18
183	171	33	84	84	2026-01-05
184	172	8	60	60	2026-01-09
185	173	39	90	90	2026-01-06
186	174	4	168	168	2026-01-04
187	175	5	288	288	2026-01-08
188	176	9	312	312	2026-01-07
189	177	10	144	144	2026-01-03
190	178	13	96	96	2026-01-20
191	178	17	48	48	2026-01-05
192	179	18	288	288	2026-01-21
193	180	21	192	192	2026-01-10
194	181	28	48	48	2026-01-10
195	182	28	48	48	2026-01-07
196	183	28	48	48	2026-01-07
197	184	34	72	72	2026-01-05
198	185	40	36	36	2026-01-15
199	186	10	144	144	2026-01-05
200	187	15	132	132	2026-01-15
201	188	16	288	288	2026-01-17
202	189	12	432	432	2026-01-07
203	190	31	528	528	2026-01-26
204	191	7	24	24	2026-01-13
205	192	18	264	264	2026-01-29
206	193	40	48	48	2026-01-21
207	194	5	312	312	2026-01-12
208	195	11	36	36	2026-01-14
209	196	16	288	288	2026-01-18
210	197	33	78	78	2026-01-16
211	198	9	360	360	2026-01-11
212	199	19	168	168	2026-01-13
213	200	21	192	192	2026-01-22
214	201	26	108	97	2026-02-02
215	202	26	108	108	2026-01-31
216	203	26	108	108	2026-01-29
217	199	37	576	576	2026-01-13
218	204	6	360	360	2026-01-12
219	205	9	312	312	2026-01-11
220	206	12	432	432	2026-01-12
221	207	17	54	54	2026-01-14
222	208	35	72	72	2026-01-15
223	209	2	84	84	2026-02-03
224	210	8	60	60	2026-01-24
225	211	8	54	54	2026-01-26
226	212	14	96	96	2026-01-27
227	213	22	54	54	2026-01-20
228	214	23	120	120	2026-01-27
229	215	4	168	168	2026-01-16
230	216	32	30	30	2026-01-21
231	217	37	528	528	2026-01-16
232	218	38	192	192	2026-01-23
233	219	1	48	48	2026-01-18
234	220	10	144	144	2026-01-19
235	221	12	432	432	2026-01-19
236	222	18	216	216	2026-02-06
237	223	25	72	72	2026-02-01
238	224	33	90	90	2026-01-22
239	225	7	36	36	2026-01-21
240	226	22	66	66	2026-01-21
241	227	25	72	72	2026-02-03
242	228	23	132	132	2026-01-27
243	229	4	156	156	2026-01-19
244	230	14	96	96	2026-02-03
245	231	17	66	66	2026-01-22
246	232	20	66	66	2026-02-08
247	233	22	54	54	2026-01-26
248	234	24	336	336	2026-01-22
249	235	36	168	168	2026-01-28
250	236	38	180	180	2026-01-26
251	237	39	90	90	2026-01-24
252	238	3	132	132	2026-01-28
253	239	18	240	240	2026-02-08
254	240	24	336	336	2026-01-28
255	241	31	624	624	2026-02-13
256	242	37	600	600	2026-01-25
257	243	40	36	36	2026-02-01
258	244	6	360	360	2026-01-30
259	245	8	60	60	2026-02-02
260	246	36	120	120	2026-02-01
261	247	38	180	180	2026-01-27
262	248	12	432	432	2026-01-27
263	249	30	264	264	2026-02-03
264	250	30	264	264	2026-02-08
265	251	30	264	264	2026-02-07
266	252	19	192	192	2026-02-03
267	253	11	42	42	2026-02-04
268	254	2	84	84	2026-02-15
269	255	2	84	84	2026-02-17
270	256	4	156	156	2026-01-29
271	257	9	336	336	2026-01-28
272	258	18	216	216	2026-02-17
273	259	29	72	72	2026-02-15
274	260	29	72	72	2026-02-12
275	261	29	72	72	2026-02-16
276	259	31	600	600	2026-02-14
277	262	24	312	312	2026-02-05
278	263	27	132	132	2026-01-30
279	264	27	132	132	2026-01-29
280	265	27	132	132	2026-01-31
281	266	16	288	288	2026-02-09
282	267	17	48	48	2026-01-29
283	268	22	60	60	2026-02-02
284	269	28	48	48	2026-01-29
285	270	28	48	48	2026-02-04
286	271	28	48	48	2026-02-08
287	272	33	90	90	2026-02-04
288	273	39	90	90	2026-02-08
289	274	11	30	30	2026-02-07
290	275	38	168	168	2026-02-04
291	274	39	90	90	2026-02-04
292	276	1	54	49	2026-02-03
293	277	23	132	132	2026-02-10
294	278	40	42	42	2026-02-14
295	279	5	312	312	2026-02-08
296	280	32	36	36	2026-02-08
297	281	5	264	264	2026-02-08
298	282	9	312	312	2026-02-04
299	283	9	312	312	2026-02-03
300	284	16	288	288	2026-02-13
301	285	20	72	72	2026-02-18
302	286	34	72	72	2026-02-09
303	287	1	54	54	2026-02-03
304	288	6	360	360	2026-02-08
305	289	10	120	120	2026-02-05
306	290	13	108	108	2026-02-24
307	291	16	288	288	2026-02-15
308	292	21	240	240	2026-02-18
309	293	12	456	456	2026-02-08
310	294	14	96	96	2026-02-18
311	295	13	96	96	2026-02-27
312	296	22	54	54	2026-02-12
313	297	34	48	48	2026-02-13
314	298	38	204	204	2026-02-14
315	299	4	216	216	2026-02-08
316	300	7	30	30	2026-02-14
317	301	23	156	156	2026-02-20
318	302	31	576	576	2026-03-02
319	303	35	72	72	2026-02-10
320	304	7	36	36	2026-02-13
321	305	15	120	120	2026-02-23
322	306	12	504	504	2026-02-11
323	307	15	144	144	2026-02-22
324	307	17	60	60	2026-02-13
325	308	21	240	240	2026-02-22
326	309	36	120	120	2026-02-14
327	310	36	144	144	2026-02-13
328	311	36	168	168	2026-02-17
329	307	37	576	576	2026-02-13
330	312	4	168	168	2026-02-12
331	313	12	432	432	2026-02-14
332	314	33	84	84	2026-02-18
333	315	33	90	90	2026-02-22
334	316	6	384	384	2026-02-21
335	317	15	156	156	2026-02-26
336	317	19	144	144	2026-02-18
337	318	13	144	144	2026-03-06
338	318	19	168	168	2026-02-20
339	319	40	48	48	2026-03-01
340	320	23	120	120	2026-02-25
341	321	31	600	540	2026-03-08
342	322	5	336	336	2026-02-21
343	323	24	288	288	2026-02-23
344	324	1	42	42	2026-02-17
345	325	2	90	90	2026-03-08
346	326	2	96	96	2026-03-09
347	327	10	120	120	2026-02-22
348	328	20	66	66	2026-03-11
349	329	20	72	72	2026-03-12
350	330	37	528	528	2026-02-18
351	331	8	54	54	2026-03-04
352	332	1	48	48	2026-02-19
353	333	2	84	84	2026-03-13
354	334	9	360	360	2026-02-22
355	335	11	36	36	2026-02-25
356	336	25	72	72	2026-03-05
357	337	13	132	132	2026-03-13
358	338	14	84	84	2026-03-03
359	339	18	240	240	2026-03-12
360	340	25	102	102	2026-03-06
361	341	26	108	108	2026-03-14
362	342	26	108	108	2026-03-11
363	343	26	108	108	2026-03-11
364	337	37	600	600	2026-02-24
365	344	3	96	96	2026-03-01
366	345	13	96	96	2026-03-12
367	345	15	132	132	2026-03-07
368	346	21	216	216	2026-03-06
369	347	29	72	72	2026-03-14
370	348	29	72	72	2026-03-11
371	349	29	72	72	2026-03-19
372	348	35	72	72	2026-02-22
373	350	36	120	120	2026-02-26
374	351	3	108	108	2026-03-01
375	352	7	24	24	2026-02-27
376	353	38	180	180	2026-02-26
377	354	6	384	384	2026-03-02
378	355	9	336	336	2026-02-24
379	356	28	48	48	2026-03-01
380	357	28	48	48	2026-03-01
381	358	28	48	48	2026-03-06
382	359	34	72	72	2026-03-06
383	360	38	180	180	2026-03-02
384	361	11	36	36	2026-03-02
385	361	17	60	54	2026-02-28
386	362	40	48	48	2026-03-08
387	363	19	144	144	2026-03-06
388	364	30	264	264	2026-03-13
389	365	30	264	264	2026-03-09
390	366	30	264	264	2026-03-08
391	367	12	432	432	2026-03-03
392	368	20	72	72	2026-03-19
393	369	24	336	336	2026-03-07
394	370	32	36	36	2026-03-06
395	371	35	72	72	2026-03-01
396	372	3	108	108	2026-03-04
397	373	16	276	276	2026-03-12
398	374	16	300	300	2026-03-09
399	375	22	54	54	2026-03-07
400	376	35	72	72	2026-03-05
401	377	7	30	30	2026-03-07
402	378	15	120	120	2026-03-18
403	379	23	144	144	2026-03-16
404	380	24	288	288	2026-03-10
405	381	27	132	132	2026-03-02
406	382	27	132	132	2026-03-05
407	383	27	132	132	2026-03-07
408	384	39	96	96	2026-03-11
409	385	8	54	54	2026-03-16
410	386	14	96	96	2026-03-16
411	387	6	336	336	2026-03-15
412	387	7	30	30	2026-03-09
413	388	17	66	66	2026-03-08
414	389	31	576	576	2026-03-26
415	390	32	42	42	2026-03-11
416	389	33	84	84	2026-03-12
417	391	35	84	84	2026-03-07
418	392	8	54	54	2026-03-25
419	393	31	576	576	2026-03-23
420	394	5	264	264	2026-03-13
421	395	6	384	384	2026-03-18
422	396	13	96	86	2026-03-30
423	397	19	144	144	2026-03-12
424	398	33	78	78	2026-03-12
425	399	1	54	54	2026-03-12
426	400	5	312	312	2026-03-19
427	401	12	432	432	2026-03-13
428	402	8	60	60	2026-03-25
429	403	13	84	84	2026-03-30
430	404	32	30	30	2026-03-16
431	403	37	552	552	2026-03-14
432	405	6	336	336	2026-03-16
433	406	15	144	144	2026-03-23
434	407	16	300	300	2026-03-24
435	408	24	336	336	2026-03-19
436	409	35	72	72	2026-03-13
437	410	40	48	48	2026-03-23
438	411	4	156	156	2026-03-17
439	412	17	54	54	2026-03-18
440	413	19	240	216	2026-03-21
441	414	25	96	96	2026-03-24
442	412	39	90	90	2026-03-22
443	415	40	36	36	2026-03-28
444	416	2	90	90	2026-04-05
445	417	19	192	192	2026-03-20
446	418	31	576	576	2026-04-01
447	419	37	528	528	2026-03-23
448	420	1	48	48	2026-03-17
449	421	12	432	432	2026-03-16
450	422	14	72	72	2026-03-25
451	423	18	216	216	2026-04-06
452	424	19	144	144	2026-03-22
453	423	20	66	66	2026-04-06
454	425	34	60	60	2026-03-21
455	426	2	84	84	2026-04-07
456	426	4	156	156	2026-03-21
457	427	11	42	42	2026-03-21
458	428	1	48	48	2026-03-22
459	429	3	96	96	2026-03-24
460	430	4	168	168	2026-03-21
461	431	14	84	84	2026-03-25
462	432	24	288	288	2026-03-23
463	433	33	84	84	2026-03-23
464	434	7	36	36	2026-03-28
465	435	8	54	54	2026-03-31
466	436	5	264	264	2026-03-29
467	437	20	66	66	2026-04-10
468	438	8	54	54	2026-04-06
469	439	12	456	456	2026-03-23
470	440	17	48	48	2026-03-21
471	441	38	204	204	2026-03-28
472	442	9	336	336	2026-03-22
473	443	13	96	96	2026-04-12
474	444	28	48	48	2026-03-28
475	445	28	48	48	2026-03-31
476	446	28	48	48	2026-04-01
477	447	31	528	528	2026-04-12
478	448	3	96	96	2026-04-02
479	449	9	336	336	2026-03-25
480	450	15	132	132	2026-04-03
481	451	36	192	173	2026-03-29
482	452	38	180	180	2026-03-30
483	451	38	216	216	2026-03-30
484	450	39	102	102	2026-03-31
485	453	2	84	84	2026-04-14
486	454	7	24	24	2026-04-02
487	455	13	108	108	2026-04-13
488	456	13	120	120	2026-04-14
489	457	21	192	192	2026-04-05
490	458	40	36	36	2026-04-05
491	459	14	72	72	2026-04-10
492	460	15	132	132	2026-04-10
493	461	23	144	144	2026-04-07
494	462	4	156	156	2026-03-30
495	463	6	336	336	2026-04-05
496	464	33	84	84	2026-03-31
497	465	1	48	48	2026-03-31
498	465	3	96	96	2026-04-05
499	466	7	36	36	2026-04-19
500	467	15	132	132	2026-04-12
501	468	16	300	300	2026-04-11
502	469	22	66	66	2026-04-04
503	470	31	528	528	2026-04-18
504	467	39	90	90	2026-04-04
505	471	31	576	576	2026-04-18
506	472	37	528	528	2026-04-03
507	473	1	54	54	2026-03-31
508	473	3	96	96	2026-04-08
509	474	9	336	336	2026-04-22
510	474	10	120	120	2026-04-26
511	475	18	216	216	2026-04-24
512	476	21	240	240	2026-04-15
513	477	24	288	288	2026-04-07
514	478	25	72	72	2026-04-13
515	479	26	108	108	2026-04-16
516	480	26	108	108	2026-04-19
517	481	26	108	108	2026-04-20
518	482	4	156	156	2026-04-03
519	483	6	384	384	2026-04-28
520	484	18	216	216	2026-04-24
521	485	19	216	216	2026-04-03
522	486	32	36	36	2026-04-10
523	487	35	96	96	2026-04-01
524	488	1	48	48	2026-04-05
525	489	10	96	96	2026-04-21
526	490	10	144	144	2026-04-22
527	491	21	192	192	2026-04-17
528	492	23	120	120	2026-04-18
529	493	40	42	42	2026-04-22
530	494	9	312	312	2026-04-30
531	495	11	36	36	2026-04-09
532	496	12	432	432	2026-04-05
533	497	16	276	276	2026-04-16
534	498	36	144	144	2026-04-10
535	499	34	48	48	2026-04-09
536	500	36	144	130	2026-04-10
537	501	3	96	96	2026-04-10
538	502	37	552	552	2026-04-12
539	503	2	90	90	2026-04-26
540	504	13	144	144	2026-04-25
541	505	2	84	84	2026-04-30
542	506	18	216	216	2026-04-29
543	507	19	144	144	2026-04-14
544	508	30	264	264	2026-04-22
545	509	30	264	264	2026-04-18
546	510	30	264	264	2026-04-19
547	511	33	90	90	2026-04-15
548	512	34	48	48	2026-04-15
549	511	35	72	72	2026-04-06
550	513	40	36	36	2026-04-23
551	514	14	84	84	2026-04-21
552	515	5	264	264	2026-04-18
553	516	1	42	42	2026-04-16
554	517	8	66	66	2026-05-15
555	518	12	432	432	2026-04-12
556	519	17	54	54	2026-04-15
557	519	19	192	192	2026-04-16
558	520	20	72	72	2026-05-01
559	521	33	78	78	2026-04-17
560	521	35	84	84	2026-04-16
561	522	36	96	96	2026-04-14
562	523	2	96	96	2026-05-07
563	524	13	84	84	2026-05-02
564	525	38	204	204	2026-04-20
565	526	4	168	151	2026-04-18
566	527	4	156	156	2026-04-20
567	528	5	264	264	2026-04-23
568	529	8	48	48	2026-05-12
569	530	24	288	288	2026-04-23
570	531	25	84	84	2026-04-27
571	532	27	132	132	2026-04-17
572	533	27	132	132	2026-04-15
573	534	27	132	132	2026-04-16
574	535	39	90	90	2026-04-18
575	536	12	456	456	2026-04-24
576	537	15	120	120	2026-04-29
577	538	21	192	192	2026-04-29
578	539	6	360	360	2026-05-13
579	540	22	66	66	2026-04-23
580	541	31	624	624	2026-05-05
581	542	3	144	144	2026-04-24
582	543	13	108	108	2026-05-07
583	544	14	72	72	2026-04-28
584	543	15	120	120	2026-05-03
585	545	32	36	36	2026-04-24
586	543	39	96	96	2026-04-22
587	546	4	156	156	2026-04-16
588	547	6	360	360	2026-05-18
589	548	24	288	288	2026-04-27
590	549	8	54	54	2026-05-23
591	550	24	288	288	2026-04-23
592	551	5	264	264	2026-04-26
593	552	35	84	84	2026-04-21
594	553	38	180	180	2026-04-28
595	554	17	66	66	2026-04-23
596	555	29	72	72	2026-05-14
597	556	29	72	72	2026-05-10
598	557	29	72	72	2026-05-11
599	557	31	528	528	2026-05-14
600	554	37	552	552	2026-04-25
601	558	2	90	90	2026-05-12
602	559	25	78	78	2026-05-08
603	560	32	36	36	2026-04-30
604	561	38	192	192	2026-05-01
605	562	7	30	25	2026-05-24
606	563	14	84	84	2026-05-05
607	564	16	288	288	2026-05-10
608	565	20	84	84	2026-05-10
609	566	36	120	120	2026-05-02
610	567	19	144	144	2026-05-01
611	568	33	78	78	2026-05-04
612	569	5	264	264	2026-05-04
613	570	17	66	66	2026-05-01
614	571	31	528	528	2026-05-21
615	572	7	24	24	2026-05-29
616	573	11	30	30	2026-05-04
617	574	16	288	288	2026-05-09
618	575	22	60	60	2026-05-03
619	576	34	48	48	2026-05-02
620	577	37	528	528	2026-05-03
621	578	3	96	96	2026-05-08
622	579	39	90	90	2026-05-11
623	580	13	108	108	2026-05-19
624	581	16	276	276	2026-05-13
625	582	22	60	60	2026-05-09
626	583	4	180	180	2026-05-02
627	584	5	264	264	2026-05-09
628	585	12	432	432	2026-05-06
629	586	13	96	86	2026-05-24
630	587	15	132	132	2026-05-18
631	588	1	54	54	2026-05-03
632	589	23	132	132	2026-05-18
633	590	37	576	576	2026-05-07
634	591	14	84	84	2026-05-21
635	592	20	66	66	2026-05-26
636	593	23	120	120	2026-05-23
637	594	2	96	96	2026-05-31
638	595	3	108	108	2026-05-15
639	596	4	180	180	2026-05-13
640	597	8	54	54	2026-06-15
641	597	10	120	120	2026-06-03
642	598	15	120	120	2026-05-21
643	599	40	36	36	2026-05-23
644	600	32	30	30	2026-05-14
645	601	5	312	312	2026-05-18
646	602	9	312	312	2026-06-06
647	603	12	480	480	2026-05-14
648	603	14	72	72	2026-05-29
649	604	9	336	336	2026-06-08
650	605	18	240	240	2026-05-30
651	605	20	66	66	2026-06-06
652	606	21	240	240	2026-05-24
653	607	32	42	42	2026-05-21
654	608	39	90	90	2026-05-19
655	609	3	120	120	2026-05-22
656	610	6	360	251	2026-06-02
657	611	10	96	59	2026-05-31
658	612	34	48	48	2026-05-20
659	613	4	156	156	2026-05-17
660	614	12	456	456	2026-05-17
661	615	18	240	240	2026-06-02
662	616	21	192	192	2026-05-23
663	616	23	132	132	2026-05-27
664	617	31	576	576	2026-06-04
665	618	3	108	108	2026-05-22
666	619	8	60	41	2026-06-20
667	620	25	84	84	2026-05-26
668	621	31	552	552	2026-06-07
669	622	36	120	120	2026-05-23
670	623	36	144	144	2026-05-24
671	624	15	132	132	2026-05-29
672	625	38	192	192	2026-05-18
673	626	1	42	42	2026-05-22
674	627	2	84	84	2026-06-06
675	628	11	36	36	2026-05-26
676	629	14	72	72	2026-05-31
677	630	34	60	60	2026-05-24
678	631	38	192	192	2026-05-25
679	632	1	48	48	2026-05-22
680	633	10	120	120	2026-06-11
681	634	11	48	48	2026-05-31
682	635	17	54	54	2026-05-25
683	636	26	108	108	2026-06-11
684	637	26	108	108	2026-06-11
685	638	26	108	108	2026-06-11
686	639	1	54	54	2026-05-24
687	640	13	96	96	2026-06-11
688	641	13	108	108	2026-06-09
689	641	15	120	120	2026-06-03
690	642	16	312	312	2026-06-04
691	641	19	192	192	2026-05-29
692	643	25	72	72	2026-06-05
693	644	33	90	90	2026-05-30
694	645	40	36	36	2026-06-06
695	646	5	264	264	2026-06-02
696	647	8	60	41	2026-06-30
697	648	14	84	84	2026-06-11
698	649	35	72	72	2026-05-24
699	650	39	90	90	2026-06-04
700	651	14	84	84	2026-06-08
701	652	24	312	312	2026-06-03
702	653	12	456	456	2026-05-29
703	654	19	144	144	2026-06-04
704	655	32	30	30	2026-06-06
705	656	33	84	84	2026-05-31
706	657	34	72	72	2026-06-03
707	658	5	264	264	2026-06-02
708	659	6	336	336	2026-06-26
709	660	22	54	54	2026-06-06
710	661	24	336	336	2026-06-03
711	662	31	696	696	2026-06-14
712	663	35	72	72	2026-05-30
713	664	39	90	90	2026-06-04
714	665	23	144	144	2026-06-14
715	666	12	432	432	2026-05-30
716	667	28	48	48	2026-06-07
717	668	28	48	48	2026-06-07
718	669	28	48	48	2026-06-05
719	670	35	96	96	2026-06-03
720	671	1	48	48	2026-06-05
721	672	3	96	96	2026-06-08
722	673	4	168	168	2026-06-03
723	674	9	312	312	2026-06-26
724	675	24	360	360	2026-06-09
725	676	33	78	78	2026-06-08
726	677	36	120	120	2026-06-11
727	678	2	90	90	2026-06-23
728	679	16	288	288	2026-06-17
729	680	40	54	54	2026-06-13
730	681	11	36	36	2026-06-12
731	681	37	528	528	2026-06-07
732	682	1	42	42	2026-06-06
733	682	3	108	108	2026-06-11
734	683	4	180	180	2026-06-07
735	684	8	48	48	2026-07-07
736	685	31	576	576	2026-06-29
737	686	37	528	528	2026-06-09
738	687	32	30	30	2026-06-13
739	688	5	264	238	2026-06-13
740	689	2	96	96	2026-06-25
741	690	13	84	84	2026-06-28
742	690	17	48	48	2026-06-11
743	691	31	528	528	2026-07-01
744	692	1	42	42	2026-06-12
745	693	2	90	90	2026-06-30
746	694	6	408	408	2026-07-04
747	695	11	36	36	2026-06-16
748	696	5	264	264	2026-06-20
749	697	6	360	360	2026-07-01
750	698	13	96	96	2026-07-02
751	699	21	192	192	2026-06-22
752	700	4	204	204	2026-06-14
753	701	10	144	87	2026-06-26
754	702	18	216	216	2026-07-03
755	703	37	528	528	2026-06-16
756	704	3	96	96	2026-06-19
757	705	4	156	156	2026-06-16
758	706	7	36	30	2026-07-05
759	707	7	30	19	2026-07-03
760	708	13	120	120	2026-07-01
761	709	12	432	432	2026-06-14
762	710	25	72	72	2026-06-23
763	711	1	54	54	2026-06-20
764	712	17	60	60	2026-06-16
765	713	21	192	192	2026-06-29
766	714	29	72	72	2026-07-04
767	715	29	72	72	2026-07-05
768	716	29	72	72	2026-07-05
769	717	38	180	180	2026-06-22
770	718	1	42	42	2026-06-18
771	719	3	144	144	2026-06-23
772	720	38	216	216	2026-06-23
773	721	5	264	264	2026-06-26
774	722	7	36	25	2026-07-18
775	723	13	84	84	2026-07-10
776	724	15	144	144	2026-07-01
777	725	32	30	30	2026-06-21
778	726	2	108	108	2026-07-09
779	727	5	264	264	2026-06-23
780	728	12	456	456	2026-06-21
781	729	16	300	300	2026-06-30
782	730	33	90	90	2026-06-29
783	731	2	120	120	2026-07-09
784	732	14	84	84	2026-07-02
785	733	30	264	264	2026-06-28
786	734	30	264	264	2026-07-05
787	735	30	264	264	2026-07-05
788	736	34	48	48	2026-06-27
789	737	1	42	42	2026-06-21
790	738	11	36	36	2026-06-26
791	739	25	84	84	2026-07-07
792	740	8	66	66	2026-07-20
793	741	39	90	90	2026-06-28
794	742	5	264	264	2026-06-29
795	743	19	144	144	2026-07-02
796	744	4	156	156	2026-06-26
797	745	4	168	168	2026-06-26
798	746	20	72	72	2026-07-11
799	747	23	120	120	2026-07-04
800	748	5	264	264	2026-07-02
801	749	9	336	336	2026-07-13
802	750	9	312	312	2026-07-19
803	751	10	168	168	2026-07-21
804	752	13	108	108	2026-07-16
805	753	24	288	288	2026-07-01
806	754	31	552	552	2026-07-15
807	755	39	102	102	2026-07-03
808	756	2	108	97	2026-07-17
809	757	3	96	96	2026-06-30
810	756	4	156	156	2026-06-29
811	758	11	36	36	2026-07-06
812	759	12	432	432	2026-06-26
813	760	25	78	78	2026-07-08
814	761	35	84	84	2026-06-24
815	762	36	144	144	2026-07-04
816	763	21	216	216	2026-07-11
817	764	31	552	552	2026-07-17
818	765	16	288	288	2026-07-11
819	766	22	66	66	2026-07-06
820	767	28	48	48	2026-07-08
821	768	28	48	48	2026-07-05
822	769	28	48	48	2026-07-03
823	770	34	60	60	2026-07-03
824	771	15	132	132	2026-07-12
825	772	1	42	42	2026-07-04
826	773	3	96	96	2026-07-08
827	774	8	54	0	\N
828	775	1	42	42	2026-07-03
829	776	3	96	96	2026-07-09
830	777	12	432	432	2026-07-03
831	778	27	132	132	2026-07-06
832	779	27	132	132	2026-07-06
833	780	27	132	132	2026-07-06
834	781	10	120	120	2026-07-25
835	782	32	36	36	2026-07-08
836	783	18	216	216	2026-07-24
837	784	20	72	72	2026-07-27
838	785	35	72	72	2026-07-04
839	786	6	360	360	2026-07-27
840	787	18	216	216	2026-07-26
841	788	1	54	49	2026-07-10
842	789	4	192	192	2026-07-10
843	790	5	264	264	2026-07-13
844	791	7	30	0	\N
845	792	14	72	72	2026-07-19
846	793	31	528	528	2026-07-22
847	794	32	48	48	2026-07-11
848	794	34	72	72	2026-07-15
849	793	35	84	84	2026-07-08
850	795	36	120	120	2026-07-14
851	796	37	648	648	2026-07-07
852	797	39	108	108	2026-07-14
853	798	4	180	180	2026-07-05
854	799	14	96	96	2026-07-25
855	800	15	156	156	2026-07-17
856	801	34	48	48	2026-07-17
857	802	40	42	42	2026-07-23
858	803	1	42	42	2026-07-12
859	804	2	84	84	2026-07-31
860	805	5	264	264	2026-07-16
861	806	6	360	0	\N
862	806	8	54	0	\N
863	807	12	552	552	2026-07-16
864	808	31	528	0	\N
865	809	33	84	84	2026-07-16
866	810	2	90	90	2026-07-28
867	811	33	78	78	2026-07-18
868	812	36	96	96	2026-07-16
869	813	1	48	48	2026-07-12
870	813	3	96	96	2026-07-19
871	814	3	156	156	2026-07-21
872	815	4	156	156	2026-07-16
873	816	13	120	0	\N
874	817	19	144	144	2026-07-17
875	818	24	312	312	2026-07-19
876	819	32	36	36	2026-07-16
877	820	5	264	264	2026-07-17
878	821	38	192	192	2026-07-18
879	822	7	36	0	\N
880	822	9	336	336	2026-07-29
881	823	11	36	36	2026-07-20
882	824	15	120	120	2026-07-26
883	825	38	192	192	2026-07-17
884	826	8	60	0	\N
885	827	13	96	0	\N
886	828	23	144	144	2026-07-30
887	829	40	42	42	2026-07-28
888	830	4	192	192	2026-07-17
889	831	12	432	432	2026-07-17
890	832	17	60	60	2026-07-20
891	833	24	312	312	2026-07-24
892	834	33	90	90	2026-07-23
893	835	8	54	0	\N
894	836	11	36	36	2026-07-21
895	837	14	84	84	2026-07-30
896	838	21	216	216	2026-07-30
897	836	37	528	528	2026-07-20
898	839	1	54	54	2026-07-20
899	840	2	96	0	\N
900	839	5	264	264	2026-07-23
901	841	13	96	0	\N
902	842	26	108	0	\N
903	843	26	108	0	\N
904	844	26	108	0	\N
905	845	38	180	180	2026-07-24
906	846	35	84	76	2026-07-24
907	847	1	60	60	2026-07-25
908	848	22	66	66	2026-07-27
909	849	25	72	0	\N
910	850	4	156	156	2026-07-28
911	851	12	432	432	2026-07-25
912	852	22	60	0	\N
913	853	36	120	0	\N
914	854	2	84	0	\N
915	855	18	216	0	\N
916	856	40	48	0	\N
917	857	7	36	0	\N
918	858	22	60	60	2026-07-30
919	859	1	42	42	2026-07-29
920	860	2	84	0	\N
921	859	3	156	0	\N
922	861	4	168	168	2026-07-29
923	862	8	60	0	\N
924	863	11	42	0	\N
925	864	31	552	0	\N
926	863	39	90	0	\N
927	865	4	192	192	2026-07-31
928	866	5	264	0	\N
929	867	5	336	0	\N
930	868	23	120	0	\N
931	869	31	528	0	\N
932	869	33	90	0	\N
933	870	35	84	0	\N
934	871	39	90	0	\N
935	872	2	90	0	\N
936	873	3	120	0	\N
937	874	13	96	0	\N
938	874	15	120	0	\N
939	874	19	144	0	\N
940	875	20	84	0	\N
941	876	35	72	72	2026-07-31
942	874	37	528	528	2026-07-31
943	877	37	552	552	2026-07-29
944	878	15	120	0	\N
945	879	15	132	0	\N
946	880	20	66	0	\N
947	881	6	360	0	\N
948	882	14	96	0	\N
949	883	24	336	0	\N
950	884	32	42	0	\N
951	885	34	60	0	\N
952	886	16	276	0	\N
953	887	1	48	0	\N
954	888	5	288	0	\N
955	889	6	336	0	\N
956	890	7	30	0	\N
957	891	33	84	0	\N
958	892	3	108	0	\N
959	893	9	336	0	\N
960	893	10	120	0	\N
961	894	18	216	0	\N
962	895	31	552	0	\N
963	896	1	48	0	\N
964	897	16	288	0	\N
965	898	34	48	0	\N
966	899	1	54	0	\N
967	900	4	204	0	\N
968	901	12	456	0	\N
\.
COPY inventory_snapshots (snapshot_date, product_id, dc_id, qty_on_hand) FROM stdin;
2025-11-09	1	1	40
2025-11-09	1	2	54
2025-11-09	1	3	44
2025-11-09	2	1	180
2025-11-09	2	2	160
2025-11-09	2	3	162
2025-11-09	3	1	108
2025-11-09	3	2	120
2025-11-09	3	3	168
2025-11-09	4	1	96
2025-11-09	4	2	168
2025-11-09	4	3	193
2025-11-09	5	1	292
2025-11-09	5	2	245
2025-11-09	5	3	399
2025-11-09	6	1	537
2025-11-09	6	2	455
2025-11-09	6	3	592
2025-11-09	7	1	53
2025-11-09	7	2	26
2025-11-09	7	3	53
2025-11-09	8	1	76
2025-11-09	8	2	98
2025-11-09	8	3	99
2025-11-09	9	1	352
2025-11-09	9	2	496
2025-11-09	9	3	264
2025-11-09	10	1	144
2025-11-09	10	2	157
2025-11-09	10	3	151
2025-11-09	11	1	41
2025-11-09	11	2	58
2025-11-09	11	3	53
2025-11-09	12	1	602
2025-11-09	12	2	625
2025-11-09	12	3	637
2025-11-09	13	1	195
2025-11-09	13	2	182
2025-11-09	13	3	219
2025-11-09	14	1	144
2025-11-09	14	2	111
2025-11-09	14	3	147
2025-11-09	15	1	133
2025-11-09	15	2	170
2025-11-09	15	3	232
2025-11-09	16	1	378
2025-11-09	16	2	414
2025-11-09	16	3	435
2025-11-09	17	1	44
2025-11-09	17	2	77
2025-11-09	17	3	88
2025-11-09	18	1	440
2025-11-09	18	2	378
2025-11-09	18	3	520
2025-11-09	19	1	208
2025-11-09	19	2	214
2025-11-09	19	3	196
2025-11-09	20	1	146
2025-11-09	20	2	144
2025-11-09	20	3	135
2025-11-09	21	1	210
2025-11-09	21	2	195
2025-11-09	21	3	226
2025-11-09	22	1	67
2025-11-09	22	2	70
2025-11-09	22	3	91
2025-11-09	23	1	143
2025-11-09	23	2	3
2025-11-09	23	3	136
2025-11-09	24	1	420
2025-11-09	24	2	298
2025-11-09	24	3	303
2025-11-09	25	1	50
2025-11-09	25	2	89
2025-11-09	25	3	74
2025-11-09	26	1	242
2025-11-09	26	2	233
2025-11-09	26	3	218
2025-11-09	27	1	140
2025-11-09	27	2	173
2025-11-09	27	3	166
2025-11-09	28	1	112
2025-11-09	28	2	91
2025-11-09	28	3	91
2025-11-09	29	1	120
2025-11-09	29	2	167
2025-11-09	29	3	163
2025-11-09	30	1	375
2025-11-09	30	2	440
2025-11-09	30	3	537
2025-11-09	31	1	803
2025-11-09	31	2	1030
2025-11-09	31	3	1011
2025-11-09	32	1	41
2025-11-09	32	2	48
2025-11-09	32	3	49
2025-11-09	33	1	106
2025-11-09	33	2	139
2025-11-09	33	3	123
2025-11-09	34	1	58
2025-11-09	34	2	76
2025-11-09	34	3	81
2025-11-09	35	1	73
2025-11-09	35	2	96
2025-11-09	35	3	93
2025-11-09	36	1	227
2025-11-09	36	2	211
2025-11-09	36	3	225
2025-11-09	37	1	387
2025-11-09	37	2	685
2025-11-09	37	3	704
2025-11-09	38	1	234
2025-11-09	38	2	253
2025-11-09	38	3	222
2025-11-09	39	1	110
2025-11-09	39	2	136
2025-11-09	39	3	128
2025-11-09	40	1	77
2025-11-09	40	2	92
2025-11-09	40	3	80
2025-11-16	1	1	70
2025-11-16	1	2	54
2025-11-16	1	3	38
2025-11-16	2	1	180
2025-11-16	2	2	160
2025-11-16	2	3	162
2025-11-16	3	1	108
2025-11-16	3	2	96
2025-11-16	3	3	156
2025-11-16	4	1	96
2025-11-16	4	2	144
2025-11-16	4	3	169
2025-11-16	5	1	292
2025-11-16	5	2	197
2025-11-16	5	3	255
2025-11-16	6	1	537
2025-11-16	6	2	311
2025-11-16	6	3	424
2025-11-16	7	1	53
2025-11-16	7	2	26
2025-11-16	7	3	35
2025-11-16	8	1	76
2025-11-16	8	2	80
2025-11-16	8	3	99
2025-11-16	9	1	352
2025-11-16	9	2	352
2025-11-16	9	3	216
2025-11-16	10	1	144
2025-11-16	10	2	109
2025-11-16	10	3	151
2025-11-16	11	1	29
2025-11-16	11	2	58
2025-11-16	11	3	29
2025-11-16	12	1	602
2025-11-16	12	2	625
2025-11-16	12	3	565
2025-11-16	13	1	159
2025-11-16	13	2	182
2025-11-16	13	3	219
2025-11-16	14	1	72
2025-11-16	14	2	111
2025-11-16	14	3	123
2025-11-16	15	1	133
2025-11-16	15	2	170
2025-11-16	15	3	232
2025-11-16	16	1	378
2025-11-16	16	2	402
2025-11-16	16	3	423
2025-11-16	17	1	44
2025-11-16	17	2	77
2025-11-16	17	3	52
2025-11-16	18	1	440
2025-11-16	18	2	354
2025-11-16	18	3	520
2025-11-16	19	1	160
2025-11-16	19	2	214
2025-11-16	19	3	196
2025-11-16	20	1	146
2025-11-16	20	2	120
2025-11-16	20	3	117
2025-11-16	21	1	210
2025-11-16	21	2	147
2025-11-16	21	3	226
2025-11-16	22	1	49
2025-11-16	22	2	46
2025-11-16	22	3	61
2025-11-16	23	1	107
2025-11-16	23	2	3
2025-11-16	23	3	136
2025-11-16	24	1	420
2025-11-16	24	2	226
2025-11-16	24	3	303
2025-11-16	25	1	26
2025-11-16	25	2	65
2025-11-16	25	3	68
2025-11-16	26	1	242
2025-11-16	26	2	203
2025-11-16	26	3	218
2025-11-16	27	1	92
2025-11-16	27	2	173
2025-11-16	27	3	166
2025-11-16	28	1	112
2025-11-16	28	2	67
2025-11-16	28	3	91
2025-11-16	29	1	120
2025-11-16	29	2	143
2025-11-16	29	3	127
2025-11-16	30	1	375
2025-11-16	30	2	320
2025-11-16	30	3	465
2025-11-16	31	1	803
2025-11-16	31	2	886
2025-11-16	31	3	819
2025-11-16	32	1	41
2025-11-16	32	2	42
2025-11-16	32	3	37
2025-11-16	33	1	100
2025-11-16	33	2	127
2025-11-16	33	3	87
2025-11-16	34	1	46
2025-11-16	34	2	76
2025-11-16	34	3	57
2025-11-16	35	1	73
2025-11-16	35	2	96
2025-11-16	35	3	93
2025-11-16	36	1	227
2025-11-16	36	2	211
2025-11-16	36	3	225
2025-11-16	37	1	867
2025-11-16	37	2	469
2025-11-16	37	3	632
2025-11-16	38	1	186
2025-11-16	38	2	157
2025-11-16	38	3	198
2025-11-16	39	1	110
2025-11-16	39	2	118
2025-11-16	39	3	104
2025-11-16	40	1	77
2025-11-16	40	2	80
2025-11-16	40	3	62
2025-11-23	1	1	58
2025-11-23	1	2	54
2025-11-23	1	3	38
2025-11-23	2	1	156
2025-11-23	2	2	112
2025-11-23	2	3	126
2025-11-23	3	1	108
2025-11-23	3	2	96
2025-11-23	3	3	120
2025-11-23	4	1	264
2025-11-23	4	2	144
2025-11-23	4	3	97
2025-11-23	5	1	148
2025-11-23	5	2	341
2025-11-23	5	3	135
2025-11-23	6	1	441
2025-11-23	6	2	191
2025-11-23	6	3	280
2025-11-23	7	1	47
2025-11-23	7	2	26
2025-11-23	7	3	59
2025-11-23	8	1	64
2025-11-23	8	2	50
2025-11-23	8	3	99
2025-11-23	9	1	328
2025-11-23	9	2	256
2025-11-23	9	3	552
2025-11-23	10	1	144
2025-11-23	10	2	157
2025-11-23	10	3	151
2025-11-23	11	1	29
2025-11-23	11	2	40
2025-11-23	11	3	29
2025-11-23	12	1	410
2025-11-23	12	2	529
2025-11-23	12	3	493
2025-11-23	13	1	159
2025-11-23	13	2	170
2025-11-23	13	3	183
2025-11-23	14	1	72
2025-11-23	14	2	75
2025-11-23	14	3	75
2025-11-23	15	1	97
2025-11-23	15	2	158
2025-11-23	15	3	232
2025-11-23	16	1	306
2025-11-23	16	2	318
2025-11-23	16	3	291
2025-11-23	17	1	92
2025-11-23	17	2	47
2025-11-23	17	3	40
2025-11-23	18	1	440
2025-11-23	18	2	258
2025-11-23	18	3	496
2025-11-23	19	1	64
2025-11-23	19	2	214
2025-11-23	19	3	196
2025-11-23	20	1	104
2025-11-23	20	2	96
2025-11-23	20	3	81
2025-11-23	21	1	186
2025-11-23	21	2	75
2025-11-23	21	3	202
2025-11-23	22	1	49
2025-11-23	22	2	46
2025-11-23	22	3	61
2025-11-23	23	1	83
2025-11-23	23	2	132
2025-11-23	23	3	112
2025-11-23	24	1	396
2025-11-23	24	2	178
2025-11-23	24	3	135
2025-11-23	25	1	2
2025-11-23	25	2	23
2025-11-23	25	3	56
2025-11-23	26	1	230
2025-11-23	26	2	173
2025-11-23	26	3	200
2025-11-23	27	1	68
2025-11-23	27	2	149
2025-11-23	27	3	34
2025-11-23	28	1	112
2025-11-23	28	2	67
2025-11-23	28	3	91
2025-11-23	29	1	102
2025-11-23	29	2	131
2025-11-23	29	3	115
2025-11-23	30	1	255
2025-11-23	30	2	200
2025-11-23	30	3	417
2025-11-23	31	1	587
2025-11-23	31	2	790
2025-11-23	31	3	627
2025-11-23	32	1	41
2025-11-23	32	2	42
2025-11-23	32	3	19
2025-11-23	33	1	70
2025-11-23	33	2	109
2025-11-23	33	3	45
2025-11-23	34	1	46
2025-11-23	34	2	40
2025-11-23	34	3	21
2025-11-23	35	1	73
2025-11-23	35	2	84
2025-11-23	35	3	93
2025-11-23	36	1	155
2025-11-23	36	2	187
2025-11-23	36	3	225
2025-11-23	37	1	603
2025-11-23	37	2	349
2025-11-23	37	3	416
2025-11-23	38	1	102
2025-11-23	38	2	97
2025-11-23	38	3	198
2025-11-23	39	1	104
2025-11-23	39	2	82
2025-11-23	39	3	98
2025-11-23	40	1	77
2025-11-23	40	2	68
2025-11-23	40	3	62
2025-11-30	1	1	22
2025-11-30	1	2	18
2025-11-30	1	3	44
2025-11-30	2	1	156
2025-11-30	2	2	76
2025-11-30	2	3	108
2025-11-30	3	1	60
2025-11-30	3	2	192
2025-11-30	3	3	84
2025-11-30	4	1	204
2025-11-30	4	2	96
2025-11-30	4	3	277
2025-11-30	5	1	288
2025-11-30	5	2	341
2025-11-30	5	3	264
2025-11-30	6	1	393
2025-11-30	6	2	527
2025-11-30	6	3	112
2025-11-30	7	1	47
2025-11-30	7	2	56
2025-11-30	7	3	59
2025-11-30	8	1	58
2025-11-30	8	2	2
2025-11-30	8	3	81
2025-11-30	9	1	280
2025-11-30	9	2	160
2025-11-30	9	3	384
2025-11-30	10	1	144
2025-11-30	10	2	133
2025-11-30	10	3	79
2025-11-30	11	1	65
2025-11-30	11	2	40
2025-11-30	11	3	71
2025-11-30	12	1	290
2025-11-30	12	2	433
2025-11-30	12	3	493
2025-11-30	13	1	135
2025-11-30	13	2	170
2025-11-30	13	3	147
2025-11-30	14	1	36
2025-11-30	14	2	3
2025-11-30	14	3	51
2025-11-30	15	1	229
2025-11-30	15	2	134
2025-11-30	15	3	232
2025-11-30	16	1	258
2025-11-30	16	2	222
2025-11-30	16	3	267
2025-11-30	17	1	74
2025-11-30	17	2	83
2025-11-30	17	3	100
2025-11-30	18	1	440
2025-11-30	18	2	258
2025-11-30	18	3	496
2025-11-30	19	1	120
2025-11-30	19	2	214
2025-11-30	19	3	196
2025-11-30	20	1	86
2025-11-30	20	2	78
2025-11-30	20	3	75
2025-11-30	21	1	114
2025-11-30	21	2	3
2025-11-30	21	3	130
2025-11-30	22	1	73
2025-11-30	22	2	100
2025-11-30	22	3	61
2025-11-30	23	1	71
2025-11-30	23	2	108
2025-11-30	23	3	112
2025-11-30	24	1	372
2025-11-30	24	2	418
2025-11-30	24	3	87
2025-11-30	25	1	72
2025-11-30	25	2	5
2025-11-30	25	3	56
2025-11-30	26	1	212
2025-11-30	26	2	173
2025-11-30	26	3	182
2025-11-30	27	1	140
2025-11-30	27	2	269
2025-11-30	27	3	34
2025-11-30	28	1	112
2025-11-30	28	2	67
2025-11-30	28	3	91
2025-11-30	29	1	102
2025-11-30	29	2	131
2025-11-30	29	3	97
2025-11-30	30	1	207
2025-11-30	30	2	80
2025-11-30	30	3	273
2025-11-30	31	1	323
2025-11-30	31	2	718
2025-11-30	31	3	507
2025-11-30	32	1	23
2025-11-30	32	2	30
2025-11-30	32	3	1
2025-11-30	33	1	40
2025-11-30	33	2	97
2025-11-30	33	3	33
2025-11-30	34	1	94
2025-11-30	34	2	40
2025-11-30	34	3	21
2025-11-30	35	1	49
2025-11-30	35	2	84
2025-11-30	35	3	69
2025-11-30	36	1	83
2025-11-30	36	2	115
2025-11-30	36	3	225
2025-11-30	37	1	531
2025-11-30	37	2	757
2025-11-30	37	3	344
2025-11-30	38	1	318
2025-11-30	38	2	181
2025-11-30	38	3	102
2025-11-30	39	1	104
2025-11-30	39	2	22
2025-11-30	39	3	68
2025-11-30	40	1	65
2025-11-30	40	2	32
2025-11-30	40	3	32
2025-12-07	1	1	76
2025-12-07	1	2	42
2025-12-07	1	3	44
2025-12-07	2	1	138
2025-12-07	2	2	58
2025-12-07	2	3	90
2025-12-07	3	1	0
2025-12-07	3	2	180
2025-12-07	3	3	24
2025-12-07	4	1	180
2025-12-07	4	2	252
2025-12-07	4	3	169
2025-12-07	5	1	120
2025-12-07	5	2	341
2025-12-07	5	3	192
2025-12-07	6	1	345
2025-12-07	6	2	455
2025-12-07	6	3	88
2025-12-07	7	1	11
2025-12-07	7	2	38
2025-12-07	7	3	53
2025-12-07	8	1	58
2025-12-07	8	2	2
2025-12-07	8	3	45
2025-12-07	9	1	256
2025-12-07	9	2	424
2025-12-07	9	3	312
2025-12-07	10	1	144
2025-12-07	10	2	133
2025-12-07	10	3	175
2025-12-07	11	1	65
2025-12-07	11	2	70
2025-12-07	11	3	71
2025-12-07	12	1	530
2025-12-07	12	2	433
2025-12-07	12	3	445
2025-12-07	13	1	135
2025-12-07	13	2	146
2025-12-07	13	3	75
2025-12-07	14	1	120
2025-12-07	14	2	3
2025-12-07	14	3	15
2025-12-07	15	1	217
2025-12-07	15	2	122
2025-12-07	15	3	208
2025-12-07	16	1	234
2025-12-07	16	2	198
2025-12-07	16	3	183
2025-12-07	17	1	68
2025-12-07	17	2	83
2025-12-07	17	3	100
2025-12-07	18	1	368
2025-12-07	18	2	210
2025-12-07	18	3	448
2025-12-07	19	1	120
2025-12-07	19	2	142
2025-12-07	19	3	76
2025-12-07	20	1	74
2025-12-07	20	2	42
2025-12-07	20	3	9
2025-12-07	21	1	0
2025-12-07	21	2	0
2025-12-07	21	3	130
2025-12-07	22	1	61
2025-12-07	22	2	100
2025-12-07	22	3	61
2025-12-07	23	1	35
2025-12-07	23	2	36
2025-12-07	23	3	100
2025-12-07	24	1	372
2025-12-07	24	2	226
2025-12-07	24	3	255
2025-12-07	25	1	54
2025-12-07	25	2	0
2025-12-07	25	3	26
2025-12-07	26	1	200
2025-12-07	26	2	161
2025-12-07	26	3	170
2025-12-07	27	1	140
2025-12-07	27	2	233
2025-12-07	27	3	130
2025-12-07	28	1	112
2025-12-07	28	2	31
2025-12-07	28	3	67
2025-12-07	29	1	78
2025-12-07	29	2	89
2025-12-07	29	3	85
2025-12-07	30	1	183
2025-12-07	30	2	56
2025-12-07	30	3	273
2025-12-07	31	1	731
2025-12-07	31	2	694
2025-12-07	31	3	507
2025-12-07	32	1	23
2025-12-07	32	2	30
2025-12-07	32	3	43
2025-12-07	33	1	112
2025-12-07	33	2	97
2025-12-07	33	3	93
2025-12-07	34	1	94
2025-12-07	34	2	88
2025-12-07	34	3	93
2025-12-07	35	1	85
2025-12-07	35	2	48
2025-12-07	35	3	69
2025-12-07	36	1	83
2025-12-07	36	2	43
2025-12-07	36	3	81
2025-12-07	37	1	411
2025-12-07	37	2	565
2025-12-07	37	3	627
2025-12-07	38	1	282
2025-12-07	38	2	109
2025-12-07	38	3	6
2025-12-07	39	1	98
2025-12-07	39	2	94
2025-12-07	39	3	38
2025-12-07	40	1	53
2025-12-07	40	2	0
2025-12-07	40	3	14
2025-12-14	1	1	64
2025-12-14	1	2	84
2025-12-14	1	3	44
2025-12-14	2	1	90
2025-12-14	2	2	40
2025-12-14	2	3	90
2025-12-14	3	1	73
2025-12-14	3	2	180
2025-12-14	3	3	108
2025-12-14	4	1	144
2025-12-14	4	2	180
2025-12-14	4	3	109
2025-12-14	5	1	336
2025-12-14	5	2	149
2025-12-14	5	3	408
2025-12-14	6	1	345
2025-12-14	6	2	407
2025-12-14	6	3	400
2025-12-14	7	1	11
2025-12-14	7	2	38
2025-12-14	7	3	47
2025-12-14	8	1	82
2025-12-14	8	2	56
2025-12-14	8	3	21
2025-12-14	9	1	256
2025-12-14	9	2	256
2025-12-14	9	3	312
2025-12-14	10	1	96
2025-12-14	10	2	133
2025-12-14	10	3	175
2025-12-14	11	1	65
2025-12-14	11	2	64
2025-12-14	11	3	71
2025-12-14	12	1	458
2025-12-14	12	2	409
2025-12-14	12	3	157
2025-12-14	13	1	159
2025-12-14	13	2	146
2025-12-14	13	3	75
2025-12-14	14	1	72
2025-12-14	14	2	84
2025-12-14	14	3	99
2025-12-14	15	1	217
2025-12-14	15	2	86
2025-12-14	15	3	172
2025-12-14	16	1	522
2025-12-14	16	2	390
2025-12-14	16	3	339
2025-12-14	17	1	56
2025-12-14	17	2	77
2025-12-14	17	3	88
2025-12-14	18	1	272
2025-12-14	18	2	378
2025-12-14	18	3	400
2025-12-14	19	1	168
2025-12-14	19	2	46
2025-12-14	19	3	0
2025-12-14	20	1	68
2025-12-14	20	2	30
2025-12-14	20	3	0
2025-12-14	21	1	192
2025-12-14	21	2	168
2025-12-14	21	3	130
2025-12-14	22	1	43
2025-12-14	22	2	100
2025-12-14	22	3	61
2025-12-14	23	1	0
2025-12-14	23	2	36
2025-12-14	23	3	0
2025-12-14	24	1	324
2025-12-14	24	2	106
2025-12-14	24	3	255
2025-12-14	25	1	42
2025-12-14	25	2	54
2025-12-14	25	3	14
2025-12-14	26	1	170
2025-12-14	26	2	119
2025-12-14	26	3	116
2025-12-14	27	1	92
2025-12-14	27	2	197
2025-12-14	27	3	82
2025-12-14	28	1	112
2025-12-14	28	2	0
2025-12-14	28	3	67
2025-12-14	29	1	78
2025-12-14	29	2	155
2025-12-14	29	3	67
2025-12-14	30	1	351
2025-12-14	30	2	264
2025-12-14	30	3	465
2025-12-14	31	1	515
2025-12-14	31	2	598
2025-12-14	31	3	459
2025-12-14	32	1	59
2025-12-14	32	2	54
2025-12-14	32	3	43
2025-12-14	33	1	82
2025-12-14	33	2	79
2025-12-14	33	3	33
2025-12-14	34	1	94
2025-12-14	34	2	88
2025-12-14	34	3	57
2025-12-14	35	1	73
2025-12-14	35	2	132
2025-12-14	35	3	57
2025-12-14	36	1	251
2025-12-14	36	2	163
2025-12-14	36	3	33
2025-12-14	37	1	363
2025-12-14	37	2	493
2025-12-14	37	3	531
2025-12-14	38	1	246
2025-12-14	38	2	193
2025-12-14	38	3	162
2025-12-14	39	1	68
2025-12-14	39	2	82
2025-12-14	39	3	110
2025-12-14	40	1	53
2025-12-14	40	2	0
2025-12-14	40	3	0
2025-12-21	1	1	46
2025-12-21	1	2	66
2025-12-21	1	3	26
2025-12-21	2	1	78
2025-12-21	2	2	106
2025-12-21	2	3	174
2025-12-21	3	1	25
2025-12-21	3	2	180
2025-12-21	3	3	96
2025-12-21	4	1	108
2025-12-21	4	2	144
2025-12-21	4	3	37
2025-12-21	5	1	264
2025-12-21	5	2	53
2025-12-21	5	3	360
2025-12-21	6	1	321
2025-12-21	6	2	311
2025-12-21	6	3	280
2025-12-21	7	1	41
2025-12-21	7	2	26
2025-12-21	7	3	35
2025-12-21	8	1	82
2025-12-21	8	2	68
2025-12-21	8	3	15
2025-12-21	9	1	112
2025-12-21	9	2	256
2025-12-21	9	3	264
2025-12-21	10	1	0
2025-12-21	10	2	61
2025-12-21	10	3	175
2025-12-21	11	1	59
2025-12-21	11	2	64
2025-12-21	11	3	71
2025-12-21	12	1	434
2025-12-21	12	2	313
2025-12-21	12	3	517
2025-12-21	13	1	159
2025-12-21	13	2	194
2025-12-21	13	3	51
2025-12-21	14	1	36
2025-12-21	14	2	156
2025-12-21	14	3	99
2025-12-21	15	1	217
2025-12-21	15	2	170
2025-12-21	15	3	148
2025-12-21	16	1	366
2025-12-21	16	2	342
2025-12-21	16	3	291
2025-12-21	17	1	8
2025-12-21	17	2	71
2025-12-21	17	3	88
2025-12-21	18	1	248
2025-12-21	18	2	378
2025-12-21	18	3	352
2025-12-21	19	1	168
2025-12-21	19	2	166
2025-12-21	19	3	144
2025-12-21	20	1	104
2025-12-21	20	2	42
2025-12-21	20	3	84
2025-12-21	21	1	192
2025-12-21	21	2	168
2025-12-21	21	3	322
2025-12-21	22	1	25
2025-12-21	22	2	100
2025-12-21	22	3	49
2025-12-21	23	1	120
2025-12-21	23	2	0
2025-12-21	23	3	0
2025-12-21	24	1	300
2025-12-21	24	2	418
2025-12-21	24	3	495
2025-12-21	25	1	30
2025-12-21	25	2	30
2025-12-21	25	3	0
2025-12-21	26	1	128
2025-12-21	26	2	107
2025-12-21	26	3	86
2025-12-21	27	1	92
2025-12-21	27	2	137
2025-12-21	27	3	70
2025-12-21	28	1	148
2025-12-21	28	2	48
2025-12-21	28	3	79
2025-12-21	29	1	102
2025-12-21	29	2	125
2025-12-21	29	3	115
2025-12-21	30	1	279
2025-12-21	30	2	192
2025-12-21	30	3	393
2025-12-21	31	1	299
2025-12-21	31	2	1006
2025-12-21	31	3	1011
2025-12-21	32	1	59
2025-12-21	32	2	54
2025-12-21	32	3	19
2025-12-21	33	1	82
2025-12-21	33	2	49
2025-12-21	33	3	9
2025-12-21	34	1	58
2025-12-21	34	2	88
2025-12-21	34	3	57
2025-12-21	35	1	73
2025-12-21	35	2	132
2025-12-21	35	3	129
2025-12-21	36	1	179
2025-12-21	36	2	115
2025-12-21	36	3	201
2025-12-21	37	1	603
2025-12-21	37	2	277
2025-12-21	37	3	483
2025-12-21	38	1	210
2025-12-21	38	2	145
2025-12-21	38	3	138
2025-12-21	39	1	68
2025-12-21	39	2	172
2025-12-21	39	3	104
2025-12-21	40	1	41
2025-12-21	40	2	66
2025-12-21	40	3	66
2025-12-28	1	1	40
2025-12-28	1	2	54
2025-12-28	1	3	80
2025-12-28	2	1	60
2025-12-28	2	2	82
2025-12-28	2	3	168
2025-12-28	3	1	84
2025-12-28	3	2	180
2025-12-28	3	3	72
2025-12-28	4	1	228
2025-12-28	4	2	84
2025-12-28	4	3	193
2025-12-28	5	1	240
2025-12-28	5	2	240
2025-12-28	5	3	288
2025-12-28	6	1	297
2025-12-28	6	2	239
2025-12-28	6	3	208
2025-12-28	7	1	41
2025-12-28	7	2	26
2025-12-28	7	3	35
2025-12-28	8	1	52
2025-12-28	8	2	68
2025-12-28	8	3	75
2025-12-28	9	1	40
2025-12-28	9	2	232
2025-12-28	9	3	264
2025-12-28	10	1	72
2025-12-28	10	2	205
2025-12-28	10	3	79
2025-12-28	11	1	59
2025-12-28	11	2	64
2025-12-28	11	3	53
2025-12-28	12	1	434
2025-12-28	12	2	433
2025-12-28	12	3	397
2025-12-28	13	1	123
2025-12-28	13	2	146
2025-12-28	13	3	147
2025-12-28	14	1	36
2025-12-28	14	2	156
2025-12-28	14	3	99
2025-12-28	15	1	145
2025-12-28	15	2	158
2025-12-28	15	3	148
2025-12-28	16	1	318
2025-12-28	16	2	342
2025-12-28	16	3	243
2025-12-28	17	1	60
2025-12-28	17	2	47
2025-12-28	17	3	70
2025-12-28	18	1	224
2025-12-28	18	2	186
2025-12-28	18	3	232
2025-12-28	19	1	120
2025-12-28	19	2	166
2025-12-28	19	3	216
2025-12-28	20	1	104
2025-12-28	20	2	12
2025-12-28	20	3	66
2025-12-28	21	1	192
2025-12-28	21	2	96
2025-12-28	21	3	322
2025-12-28	22	1	91
2025-12-28	22	2	76
2025-12-28	22	3	109
2025-12-28	23	1	120
2025-12-28	23	2	132
2025-12-28	23	3	0
2025-12-28	24	1	84
2025-12-28	24	2	418
2025-12-28	24	3	399
2025-12-28	25	1	90
2025-12-28	25	2	12
2025-12-28	25	3	78
2025-12-28	26	1	92
2025-12-28	26	2	77
2025-12-28	26	3	62
2025-12-28	27	1	176
2025-12-28	27	2	221
2025-12-28	27	3	178
2025-12-28	28	1	76
2025-12-28	28	2	0
2025-12-28	28	3	67
2025-12-28	29	1	90
2025-12-28	29	2	107
2025-12-28	29	3	115
2025-12-28	30	1	231
2025-12-28	30	2	48
2025-12-28	30	3	393
2025-12-28	31	1	227
2025-12-28	31	2	1006
2025-12-28	31	3	843
2025-12-28	32	1	59
2025-12-28	32	2	36
2025-12-28	32	3	0
2025-12-28	33	1	22
2025-12-28	33	2	127
2025-12-28	33	3	90
2025-12-28	34	1	0
2025-12-28	34	2	88
2025-12-28	34	3	57
2025-12-28	35	1	73
2025-12-28	35	2	108
2025-12-28	35	3	105
2025-12-28	36	1	179
2025-12-28	36	2	115
2025-12-28	36	3	201
2025-12-28	37	1	531
2025-12-28	37	2	829
2025-12-28	37	3	411
2025-12-28	38	1	198
2025-12-28	38	2	49
2025-12-28	38	3	282
2025-12-28	39	1	140
2025-12-28	39	2	148
2025-12-28	39	3	44
2025-12-28	40	1	89
2025-12-28	40	2	54
2025-12-28	40	3	66
2026-01-04	1	1	76
2026-01-04	1	2	48
2026-01-04	1	3	68
2026-01-04	2	1	156
2026-01-04	2	2	130
2026-01-04	2	3	150
2026-01-04	3	1	192
2026-01-04	3	2	132
2026-01-04	3	3	168
2026-01-04	4	1	216
2026-01-04	4	2	216
2026-01-04	4	3	145
2026-01-04	5	1	504
2026-01-04	5	2	168
2026-01-04	5	3	216
2026-01-04	6	1	249
2026-01-04	6	2	503
2026-01-04	6	3	280
2026-01-04	7	1	41
2026-01-04	7	2	44
2026-01-04	7	3	35
2026-01-04	8	1	52
2026-01-04	8	2	38
2026-01-04	8	3	63
2026-01-04	9	1	232
2026-01-04	9	2	160
2026-01-04	9	3	144
2026-01-04	10	1	192
2026-01-04	10	2	205
2026-01-04	10	3	7
2026-01-04	11	1	53
2026-01-04	11	2	64
2026-01-04	11	3	35
2026-01-04	12	1	386
2026-01-04	12	2	217
2026-01-04	12	3	277
2026-01-04	13	1	219
2026-01-04	13	2	122
2026-01-04	13	3	123
2026-01-04	14	1	36
2026-01-04	14	2	156
2026-01-04	14	3	99
2026-01-04	15	1	145
2026-01-04	15	2	158
2026-01-04	15	3	76
2026-01-04	16	1	270
2026-01-04	16	2	294
2026-01-04	16	3	483
2026-01-04	17	1	42
2026-01-04	17	2	47
2026-01-04	17	3	70
2026-01-04	18	1	200
2026-01-04	18	2	162
2026-01-04	18	3	64
2026-01-04	19	1	120
2026-01-04	19	2	166
2026-01-04	19	3	120
2026-01-04	20	1	92
2026-01-04	20	2	72
2026-01-04	20	3	120
2026-01-04	21	1	120
2026-01-04	21	2	96
2026-01-04	21	3	226
2026-01-04	22	1	61
2026-01-04	22	2	76
2026-01-04	22	3	103
2026-01-04	23	1	120
2026-01-04	23	2	84
2026-01-04	23	3	96
2026-01-04	24	1	84
2026-01-04	24	2	418
2026-01-04	24	3	351
2026-01-04	25	1	66
2026-01-04	25	2	0
2026-01-04	25	3	72
2026-01-04	26	1	200
2026-01-04	26	2	173
2026-01-04	26	3	164
2026-01-04	27	1	140
2026-01-04	27	2	185
2026-01-04	27	3	154
2026-01-04	28	1	76
2026-01-04	28	2	0
2026-01-04	28	3	67
2026-01-04	29	1	90
2026-01-04	29	2	89
2026-01-04	29	3	109
2026-01-04	30	1	495
2026-01-04	30	2	312
2026-01-04	30	3	657
2026-01-04	31	1	659
2026-01-04	31	2	910
2026-01-04	31	3	723
2026-01-04	32	1	41
2026-01-04	32	2	36
2026-01-04	32	3	36
2026-01-04	33	1	16
2026-01-04	33	2	115
2026-01-04	33	3	72
2026-01-04	34	1	0
2026-01-04	34	2	88
2026-01-04	34	3	57
2026-01-04	35	1	61
2026-01-04	35	2	72
2026-01-04	35	3	81
2026-01-04	36	1	179
2026-01-04	36	2	187
2026-01-04	36	3	201
2026-01-04	37	1	435
2026-01-04	37	2	757
2026-01-04	37	3	291
2026-01-04	38	1	198
2026-01-04	38	2	217
2026-01-04	38	3	234
2026-01-04	39	1	140
2026-01-04	39	2	130
2026-01-04	39	3	32
2026-01-04	40	1	89
2026-01-04	40	2	42
2026-01-04	40	3	48
2026-01-11	1	1	76
2026-01-11	1	2	36
2026-01-11	1	3	68
2026-01-11	2	1	156
2026-01-11	2	2	112
2026-01-11	2	3	150
2026-01-11	3	1	156
2026-01-11	3	2	132
2026-01-11	3	3	168
2026-01-11	4	1	144
2026-01-11	4	2	216
2026-01-11	4	3	109
2026-01-11	5	1	432
2026-01-11	5	2	408
2026-01-11	5	3	144
2026-01-11	6	1	561
2026-01-11	6	2	359
2026-01-11	6	3	184
2026-01-11	7	1	23
2026-01-11	7	2	44
2026-01-11	7	3	29
2026-01-11	8	1	82
2026-01-11	8	2	68
2026-01-11	8	3	63
2026-01-11	9	1	400
2026-01-11	9	2	448
2026-01-11	9	3	408
2026-01-11	10	1	192
2026-01-11	10	2	205
2026-01-11	10	3	79
2026-01-11	11	1	53
2026-01-11	11	2	52
2026-01-11	11	3	35
2026-01-11	12	1	290
2026-01-11	12	2	529
2026-01-11	12	3	229
2026-01-11	13	1	207
2026-01-11	13	2	122
2026-01-11	13	3	123
2026-01-11	14	1	120
2026-01-11	14	2	120
2026-01-11	14	3	63
2026-01-11	15	1	145
2026-01-11	15	2	134
2026-01-11	15	3	196
2026-01-11	16	1	174
2026-01-11	16	2	186
2026-01-11	16	3	447
2026-01-11	17	1	30
2026-01-11	17	2	77
2026-01-11	17	3	52
2026-01-11	18	1	344
2026-01-11	18	2	90
2026-01-11	18	3	40
2026-01-11	19	1	240
2026-01-11	19	2	166
2026-01-11	19	3	48
2026-01-11	20	1	62
2026-01-11	20	2	72
2026-01-11	20	3	120
2026-01-11	21	1	0
2026-01-11	21	2	288
2026-01-11	21	3	154
2026-01-11	22	1	43
2026-01-11	22	2	16
2026-01-11	22	3	97
2026-01-11	23	1	84
2026-01-11	23	2	0
2026-01-11	23	3	60
2026-01-11	24	1	324
2026-01-11	24	2	370
2026-01-11	24	3	303
2026-01-11	25	1	42
2026-01-11	25	2	72
2026-01-11	25	3	6
2026-01-11	26	1	188
2026-01-11	26	2	173
2026-01-11	26	3	140
2026-01-11	27	1	104
2026-01-11	27	2	173
2026-01-11	27	3	154
2026-01-11	28	1	124
2026-01-11	28	2	48
2026-01-11	28	3	115
2026-01-11	29	1	90
2026-01-11	29	2	65
2026-01-11	29	3	91
2026-01-11	30	1	375
2026-01-11	30	2	312
2026-01-11	30	3	657
2026-01-11	31	1	419
2026-01-11	31	2	862
2026-01-11	31	3	651
2026-01-11	32	1	41
2026-01-11	32	2	30
2026-01-11	32	3	36
2026-01-11	33	1	16
2026-01-11	33	2	97
2026-01-11	33	3	36
2026-01-11	34	1	72
2026-01-11	34	2	88
2026-01-11	34	3	57
2026-01-11	35	1	61
2026-01-11	35	2	72
2026-01-11	35	3	81
2026-01-11	36	1	155
2026-01-11	36	2	187
2026-01-11	36	3	201
2026-01-11	37	1	267
2026-01-11	37	2	493
2026-01-11	37	3	219
2026-01-11	38	1	78
2026-01-11	38	2	205
2026-01-11	38	3	186
2026-01-11	39	1	104
2026-01-11	39	2	118
2026-01-11	39	3	110
2026-01-11	40	1	83
2026-01-11	40	2	42
2026-01-11	40	3	48
2026-01-18	1	1	76
2026-01-18	1	2	66
2026-01-18	1	3	50
2026-01-18	2	1	150
2026-01-18	2	2	76
2026-01-18	2	3	150
2026-01-18	3	1	156
2026-01-18	3	2	60
2026-01-18	3	3	168
2026-01-18	4	1	120
2026-01-18	4	2	144
2026-01-18	4	3	277
2026-01-18	5	1	432
2026-01-18	5	2	408
2026-01-18	5	3	360
2026-01-18	6	1	489
2026-01-18	6	2	287
2026-01-18	6	3	472
2026-01-18	7	1	23
2026-01-18	7	2	44
2026-01-18	7	3	41
2026-01-18	8	1	64
2026-01-18	8	2	68
2026-01-18	8	3	51
2026-01-18	9	1	280
2026-01-18	9	2	304
2026-01-18	9	3	384
2026-01-18	10	1	192
2026-01-18	10	2	205
2026-01-18	10	3	55
2026-01-18	11	1	29
2026-01-18	11	2	52
2026-01-18	11	3	71
2026-01-18	12	1	146
2026-01-18	12	2	265
2026-01-18	12	3	421
2026-01-18	13	1	207
2026-01-18	13	2	86
2026-01-18	13	3	195
2026-01-18	14	1	120
2026-01-18	14	2	0
2026-01-18	14	3	63
2026-01-18	15	1	277
2026-01-18	15	2	218
2026-01-18	15	3	196
2026-01-18	16	1	438
2026-01-18	16	2	414
2026-01-18	16	3	375
2026-01-18	17	1	84
2026-01-18	17	2	65
2026-01-18	17	3	28
2026-01-18	18	1	344
2026-01-18	18	2	18
2026-01-18	18	3	160
2026-01-18	19	1	240
2026-01-18	19	2	94
2026-01-18	19	3	216
2026-01-18	20	1	122
2026-01-18	20	2	138
2026-01-18	20	3	96
2026-01-18	21	1	0
2026-01-18	21	2	216
2026-01-18	21	3	154
2026-01-18	22	1	43
2026-01-18	22	2	0
2026-01-18	22	3	91
2026-01-18	23	1	84
2026-01-18	23	2	0
2026-01-18	23	3	0
2026-01-18	24	1	324
2026-01-18	24	2	82
2026-01-18	24	3	231
2026-01-18	25	1	30
2026-01-18	25	2	72
2026-01-18	25	3	6
2026-01-18	26	1	170
2026-01-18	26	2	143
2026-01-18	26	3	140
2026-01-18	27	1	80
2026-01-18	27	2	173
2026-01-18	27	3	154
2026-01-18	28	1	88
2026-01-18	28	2	48
2026-01-18	28	3	115
2026-01-18	29	1	108
2026-01-18	29	2	131
2026-01-18	29	3	157
2026-01-18	30	1	351
2026-01-18	30	2	192
2026-01-18	30	3	585
2026-01-18	31	1	827
2026-01-18	31	2	670
2026-01-18	31	3	651
2026-01-18	32	1	41
2026-01-18	32	2	12
2026-01-18	32	3	36
2026-01-18	33	1	4
2026-01-18	33	2	91
2026-01-18	33	3	108
2026-01-18	34	1	72
2026-01-18	34	2	88
2026-01-18	34	3	57
2026-01-18	35	1	109
2026-01-18	35	2	72
2026-01-18	35	3	81
2026-01-18	36	1	83
2026-01-18	36	2	139
2026-01-18	36	3	153
2026-01-18	37	1	771
2026-01-18	37	2	277
2026-01-18	37	3	651
2026-01-18	38	1	78
2026-01-18	38	2	133
2026-01-18	38	3	174
2026-01-18	39	1	86
2026-01-18	39	2	88
2026-01-18	39	3	104
2026-01-18	40	1	65
2026-01-18	40	2	60
2026-01-18	40	3	48
2026-01-25	1	1	34
2026-01-25	1	2	66
2026-01-25	1	3	44
2026-01-25	2	1	90
2026-01-25	2	2	70
2026-01-25	2	3	114
2026-01-25	3	1	120
2026-01-25	3	2	24
2026-01-25	3	3	168
2026-01-25	4	1	204
2026-01-25	4	2	48
2026-01-25	4	3	157
2026-01-25	5	1	216
2026-01-25	5	2	384
2026-01-25	5	3	264
2026-01-25	6	1	465
2026-01-25	6	2	287
2026-01-25	6	3	328
2026-01-25	7	1	41
2026-01-25	7	2	44
2026-01-25	7	3	41
2026-01-25	8	1	46
2026-01-25	8	2	56
2026-01-25	8	3	93
2026-01-25	9	1	160
2026-01-25	9	2	232
2026-01-25	9	3	240
2026-01-25	10	1	168
2026-01-25	10	2	133
2026-01-25	10	3	175
2026-01-25	11	1	17
2026-01-25	11	2	40
2026-01-25	11	3	71
2026-01-25	12	1	410
2026-01-25	12	2	25
2026-01-25	12	3	373
2026-01-25	13	1	183
2026-01-25	13	2	182
2026-01-25	13	3	195
2026-01-25	14	1	120
2026-01-25	14	2	0
2026-01-25	14	3	63
2026-01-25	15	1	229
2026-01-25	15	2	182
2026-01-25	15	3	196
2026-01-25	16	1	390
2026-01-25	16	2	318
2026-01-25	16	3	279
2026-01-25	17	1	54
2026-01-25	17	2	47
2026-01-25	17	3	76
2026-01-25	18	1	344
2026-01-25	18	2	288
2026-01-25	18	3	40
2026-01-25	19	1	240
2026-01-25	19	2	94
2026-01-25	19	3	216
2026-01-25	20	1	110
2026-01-25	20	2	132
2026-01-25	20	3	72
2026-01-25	21	1	192
2026-01-25	21	2	216
2026-01-25	21	3	154
2026-01-25	22	1	109
2026-01-25	22	2	54
2026-01-25	22	3	49
2026-01-25	23	1	60
2026-01-25	23	2	0
2026-01-25	23	3	0
2026-01-25	24	1	252
2026-01-25	24	2	82
2026-01-25	24	3	519
2026-01-25	25	1	0
2026-01-25	25	2	72
2026-01-25	25	3	0
2026-01-25	26	1	122
2026-01-25	26	2	125
2026-01-25	26	3	104
2026-01-25	27	1	44
2026-01-25	27	2	137
2026-01-25	27	3	118
2026-01-25	28	1	88
2026-01-25	28	2	48
2026-01-25	28	3	79
2026-01-25	29	1	84
2026-01-25	29	2	89
2026-01-25	29	3	133
2026-01-25	30	1	231
2026-01-25	30	2	168
2026-01-25	30	3	585
2026-01-25	31	1	563
2026-01-25	31	2	310
2026-01-25	31	3	507
2026-01-25	32	1	41
2026-01-25	32	2	42
2026-01-25	32	3	24
2026-01-25	33	1	90
2026-01-25	33	2	91
2026-01-25	33	3	60
2026-01-25	34	1	60
2026-01-25	34	2	88
2026-01-25	34	3	21
2026-01-25	35	1	85
2026-01-25	35	2	72
2026-01-25	35	3	81
2026-01-25	36	1	59
2026-01-25	36	2	91
2026-01-25	36	3	153
2026-01-25	37	1	699
2026-01-25	37	2	733
2026-01-25	37	3	531
2026-01-25	38	1	198
2026-01-25	38	2	0
2026-01-25	38	3	114
2026-01-25	39	1	146
2026-01-25	39	2	64
2026-01-25	39	3	86
2026-01-25	40	1	59
2026-01-25	40	2	60
2026-01-25	40	3	72
2026-02-01	1	1	34
2026-02-01	1	2	60
2026-02-01	1	3	32
2026-02-01	2	1	90
2026-02-01	2	2	58
2026-02-01	2	3	96
2026-02-01	3	1	120
2026-02-01	3	2	132
2026-02-01	3	3	168
2026-02-01	4	1	204
2026-02-01	4	2	36
2026-02-01	4	3	145
2026-02-01	5	1	168
2026-02-01	5	2	384
2026-02-01	5	3	264
2026-02-01	6	1	345
2026-02-01	6	2	599
2026-02-01	6	3	256
2026-02-01	7	1	41
2026-02-01	7	2	26
2026-02-01	7	3	29
2026-02-01	8	1	28
2026-02-01	8	2	92
2026-02-01	8	3	93
2026-02-01	9	1	448
2026-02-01	9	2	136
2026-02-01	9	3	96
2026-02-01	10	1	144
2026-02-01	10	2	85
2026-02-01	10	3	175
2026-02-01	11	1	17
2026-02-01	11	2	40
2026-02-01	11	3	71
2026-02-01	12	1	338
2026-02-01	12	2	384
2026-02-01	12	3	301
2026-02-01	13	1	147
2026-02-01	13	2	182
2026-02-01	13	3	159
2026-02-01	14	1	60
2026-02-01	14	2	0
2026-02-01	14	3	147
2026-02-01	15	1	205
2026-02-01	15	2	158
2026-02-01	15	3	172
2026-02-01	16	1	246
2026-02-01	16	2	270
2026-02-01	16	3	183
2026-02-01	17	1	54
2026-02-01	17	2	59
2026-02-01	17	3	58
2026-02-01	18	1	344
2026-02-01	18	2	216
2026-02-01	18	3	264
2026-02-01	19	1	168
2026-02-01	19	2	22
2026-02-01	19	3	192
2026-02-01	20	1	92
2026-02-01	20	2	132
2026-02-01	20	3	72
2026-02-01	21	1	144
2026-02-01	21	2	168
2026-02-01	21	3	58
2026-02-01	22	1	55
2026-02-01	22	2	108
2026-02-01	22	3	25
2026-02-01	23	1	0
2026-02-01	23	2	36
2026-02-01	23	3	96
2026-02-01	24	1	156
2026-02-01	24	2	418
2026-02-01	24	3	423
2026-02-01	25	1	0
2026-02-01	25	2	60
2026-02-01	25	3	72
2026-02-01	26	1	122
2026-02-01	26	2	227
2026-02-01	26	3	212
2026-02-01	27	1	176
2026-02-01	27	2	233
2026-02-01	27	3	214
2026-02-01	28	1	136
2026-02-01	28	2	48
2026-02-01	28	3	43
2026-02-01	29	1	72
2026-02-01	29	2	83
2026-02-01	29	3	121
2026-02-01	30	1	207
2026-02-01	30	2	168
2026-02-01	30	3	465
2026-02-01	31	1	491
2026-02-01	31	2	142
2026-02-01	31	3	843
2026-02-01	32	1	41
2026-02-01	32	2	42
2026-02-01	32	3	24
2026-02-01	33	1	84
2026-02-01	33	2	79
2026-02-01	33	3	42
2026-02-01	34	1	48
2026-02-01	34	2	76
2026-02-01	34	3	9
2026-02-01	35	1	61
2026-02-01	35	2	72
2026-02-01	35	3	81
2026-02-01	36	1	179
2026-02-01	36	2	163
2026-02-01	36	3	153
2026-02-01	37	1	699
2026-02-01	37	2	565
2026-02-01	37	3	459
2026-02-01	38	1	150
2026-02-01	38	2	144
2026-02-01	38	3	282
2026-02-01	39	1	134
2026-02-01	39	2	64
2026-02-01	39	3	74
2026-02-01	40	1	59
2026-02-01	40	2	96
2026-02-01	40	3	72
2026-02-08	1	1	59
2026-02-08	1	2	60
2026-02-08	1	3	74
2026-02-08	2	1	54
2026-02-08	2	2	136
2026-02-08	2	3	54
2026-02-08	3	1	108
2026-02-08	3	2	132
2026-02-08	3	3	156
2026-02-08	4	1	204
2026-02-08	4	2	240
2026-02-08	4	3	73
2026-02-08	5	1	432
2026-02-08	5	2	192
2026-02-08	5	3	528
2026-02-08	6	1	225
2026-02-08	6	2	599
2026-02-08	6	3	400
2026-02-08	7	1	41
2026-02-08	7	2	26
2026-02-08	7	3	29
2026-02-08	8	1	88
2026-02-08	8	2	92
2026-02-08	8	3	93
2026-02-08	9	1	376
2026-02-08	9	2	448
2026-02-08	9	3	312
2026-02-08	10	1	144
2026-02-08	10	2	205
2026-02-08	10	3	127
2026-02-08	11	1	53
2026-02-08	11	2	70
2026-02-08	11	3	65
2026-02-08	12	1	218
2026-02-08	12	2	168
2026-02-08	12	3	541
2026-02-08	13	1	75
2026-02-08	13	2	182
2026-02-08	13	3	15
2026-02-08	14	1	60
2026-02-08	14	2	96
2026-02-08	14	3	111
2026-02-08	15	1	121
2026-02-08	15	2	98
2026-02-08	15	3	124
2026-02-08	16	1	210
2026-02-08	16	2	210
2026-02-08	16	3	135
2026-02-08	17	1	54
2026-02-08	17	2	53
2026-02-08	17	3	16
2026-02-08	18	1	488
2026-02-08	18	2	456
2026-02-08	18	3	264
2026-02-08	19	1	144
2026-02-08	19	2	190
2026-02-08	19	3	120
2026-02-08	20	1	74
2026-02-08	20	2	132
2026-02-08	20	3	120
2026-02-08	21	1	72
2026-02-08	21	2	168
2026-02-08	21	3	58
2026-02-08	22	1	55
2026-02-08	22	2	108
2026-02-08	22	3	85
2026-02-08	23	1	0
2026-02-08	23	2	0
2026-02-08	23	3	72
2026-02-08	24	1	420
2026-02-08	24	2	370
2026-02-08	24	3	279
2026-02-08	25	1	48
2026-02-08	25	2	60
2026-02-08	25	3	54
2026-02-08	26	1	171
2026-02-08	26	2	203
2026-02-08	26	3	200
2026-02-08	27	1	80
2026-02-08	27	2	209
2026-02-08	27	3	202
2026-02-08	28	1	112
2026-02-08	28	2	60
2026-02-08	28	3	91
2026-02-08	29	1	42
2026-02-08	29	2	83
2026-02-08	29	3	85
2026-02-08	30	1	471
2026-02-08	30	2	432
2026-02-08	30	3	585
2026-02-08	31	1	467
2026-02-08	31	2	46
2026-02-08	31	3	675
2026-02-08	32	1	41
2026-02-08	32	2	42
2026-02-08	32	3	42
2026-02-08	33	1	30
2026-02-08	33	2	49
2026-02-08	33	3	126
2026-02-08	34	1	36
2026-02-08	34	2	76
2026-02-08	34	3	0
2026-02-08	35	1	61
2026-02-08	35	2	72
2026-02-08	35	3	69
2026-02-08	36	1	131
2026-02-08	36	2	19
2026-02-08	36	3	81
2026-02-08	37	1	507
2026-02-08	37	2	445
2026-02-08	37	3	195
2026-02-08	38	1	18
2026-02-08	38	2	264
2026-02-08	38	3	222
2026-02-08	39	1	128
2026-02-08	39	2	154
2026-02-08	39	3	152
2026-02-08	40	1	35
2026-02-08	40	2	96
2026-02-08	40	3	48
2026-02-15	1	1	17
2026-02-15	1	2	36
2026-02-15	1	3	68
2026-02-15	2	1	132
2026-02-15	2	2	88
2026-02-15	2	3	24
2026-02-15	3	1	84
2026-02-15	3	2	132
2026-02-15	3	3	96
2026-02-15	4	1	132
2026-02-15	4	2	240
2026-02-15	4	3	229
2026-02-15	5	1	360
2026-02-15	5	2	96
2026-02-15	5	3	480
2026-02-15	6	1	153
2026-02-15	6	2	599
2026-02-15	6	3	256
2026-02-15	7	1	35
2026-02-15	7	2	44
2026-02-15	7	3	41
2026-02-15	8	1	70
2026-02-15	8	2	92
2026-02-15	8	3	75
2026-02-15	9	1	184
2026-02-15	9	2	376
2026-02-15	9	3	264
2026-02-15	10	1	120
2026-02-15	10	2	205
2026-02-15	10	3	103
2026-02-15	11	1	35
2026-02-15	11	2	52
2026-02-15	11	3	41
2026-02-15	12	1	674
2026-02-15	12	2	480
2026-02-15	12	3	517
2026-02-15	13	1	15
2026-02-15	13	2	158
2026-02-15	13	3	0
2026-02-15	14	1	60
2026-02-15	14	2	96
2026-02-15	14	3	63
2026-02-15	15	1	97
2026-02-15	15	2	26
2026-02-15	15	3	88
2026-02-15	16	1	414
2026-02-15	16	2	414
2026-02-15	16	3	387
2026-02-15	17	1	48
2026-02-15	17	2	53
2026-02-15	17	3	76
2026-02-15	18	1	440
2026-02-15	18	2	336
2026-02-15	18	3	216
2026-02-15	19	1	144
2026-02-15	19	2	190
2026-02-15	19	3	24
2026-02-15	20	1	50
2026-02-15	20	2	114
2026-02-15	20	3	108
2026-02-15	21	1	48
2026-02-15	21	2	96
2026-02-15	21	3	0
2026-02-15	22	1	109
2026-02-15	22	2	78
2026-02-15	22	3	79
2026-02-15	23	1	120
2026-02-15	23	2	0
2026-02-15	23	3	24
2026-02-15	24	1	300
2026-02-15	24	2	346
2026-02-15	24	3	135
2026-02-15	25	1	0
2026-02-15	25	2	36
2026-02-15	25	3	54
2026-02-15	26	1	171
2026-02-15	26	2	179
2026-02-15	26	3	182
2026-02-15	27	1	32
2026-02-15	27	2	173
2026-02-15	27	3	190
2026-02-15	28	1	112
2026-02-15	28	2	24
2026-02-15	28	3	91
2026-02-15	29	1	72
2026-02-15	29	2	149
2026-02-15	29	3	79
2026-02-15	30	1	471
2026-02-15	30	2	216
2026-02-15	30	3	585
2026-02-15	31	1	923
2026-02-15	31	2	624
2026-02-15	31	3	603
2026-02-15	32	1	41
2026-02-15	32	2	42
2026-02-15	32	3	42
2026-02-15	33	1	24
2026-02-15	33	2	37
2026-02-15	33	3	108
2026-02-15	34	1	84
2026-02-15	34	2	76
2026-02-15	34	3	60
2026-02-15	35	1	133
2026-02-15	35	2	60
2026-02-15	35	3	69
2026-02-15	36	1	251
2026-02-15	36	2	139
2026-02-15	36	3	81
2026-02-15	37	1	315
2026-02-15	37	2	277
2026-02-15	37	3	651
2026-02-15	38	1	180
2026-02-15	38	2	252
2026-02-15	38	3	210
2026-02-15	39	1	128
2026-02-15	39	2	142
2026-02-15	39	3	134
2026-02-15	40	1	71
2026-02-15	40	2	90
2026-02-15	40	3	36
2026-02-22	1	1	48
2026-02-22	1	2	66
2026-02-22	1	3	50
2026-02-22	2	1	114
2026-02-22	2	2	76
2026-02-22	2	3	90
2026-02-22	3	1	72
2026-02-22	3	2	84
2026-02-22	3	3	60
2026-02-22	4	1	132
2026-02-22	4	2	240
2026-02-22	4	3	157
2026-02-22	5	1	360
2026-02-22	5	2	336
2026-02-22	5	3	480
2026-02-22	6	1	465
2026-02-22	6	2	455
2026-02-22	6	3	40
2026-02-22	7	1	29
2026-02-22	7	2	44
2026-02-22	7	3	41
2026-02-22	8	1	52
2026-02-22	8	2	80
2026-02-22	8	3	75
2026-02-22	9	1	544
2026-02-22	9	2	304
2026-02-22	9	3	144
2026-02-22	10	1	120
2026-02-22	10	2	205
2026-02-22	10	3	223
2026-02-22	11	1	35
2026-02-22	11	2	34
2026-02-22	11	3	41
2026-02-22	12	1	650
2026-02-22	12	2	432
2026-02-22	12	3	325
2026-02-22	13	1	3
2026-02-22	13	2	158
2026-02-22	13	3	0
2026-02-22	14	1	120
2026-02-22	14	2	96
2026-02-22	14	3	63
2026-02-22	15	1	61
2026-02-22	15	2	2
2026-02-22	15	3	184
2026-02-22	16	1	330
2026-02-22	16	2	306
2026-02-22	16	3	339
2026-02-22	17	1	48
2026-02-22	17	2	17
2026-02-22	17	3	76
2026-02-22	18	1	416
2026-02-22	18	2	312
2026-02-22	18	3	432
2026-02-22	19	1	288
2026-02-22	19	2	94
2026-02-22	19	3	168
2026-02-22	20	1	110
2026-02-22	20	2	108
2026-02-22	20	3	96
2026-02-22	21	1	288
2026-02-22	21	2	96
2026-02-22	21	3	240
2026-02-22	22	1	103
2026-02-22	22	2	54
2026-02-22	22	3	79
2026-02-22	23	1	84
2026-02-22	23	2	156
2026-02-22	23	3	0
2026-02-22	24	1	300
2026-02-22	24	2	226
2026-02-22	24	3	87
2026-02-22	25	1	0
2026-02-22	25	2	36
2026-02-22	25	3	48
2026-02-22	26	1	171
2026-02-22	26	2	137
2026-02-22	26	3	164
2026-02-22	27	1	32
2026-02-22	27	2	161
2026-02-22	27	3	190
2026-02-22	28	1	112
2026-02-22	28	2	24
2026-02-22	28	3	55
2026-02-22	29	1	60
2026-02-22	29	2	149
2026-02-22	29	3	133
2026-02-22	30	1	423
2026-02-22	30	2	120
2026-02-22	30	3	513
2026-02-22	31	1	923
2026-02-22	31	2	456
2026-02-22	31	3	363
2026-02-22	32	1	35
2026-02-22	32	2	24
2026-02-22	32	3	42
2026-02-22	33	1	102
2026-02-22	33	2	90
2026-02-22	33	3	78
2026-02-22	34	1	84
2026-02-22	34	2	76
2026-02-22	34	3	12
2026-02-22	35	1	121
2026-02-22	35	2	60
2026-02-22	35	3	57
2026-02-22	36	1	251
2026-02-22	36	2	139
2026-02-22	36	3	177
2026-02-22	37	1	195
2026-02-22	37	2	589
2026-02-22	37	3	555
2026-02-22	38	1	168
2026-02-22	38	2	240
2026-02-22	38	3	138
2026-02-22	39	1	98
2026-02-22	39	2	130
2026-02-22	39	3	128
2026-02-22	40	1	53
2026-02-22	40	2	90
2026-02-22	40	3	18
2026-03-01	1	1	48
2026-03-01	1	2	54
2026-03-01	1	3	44
2026-03-01	2	1	90
2026-03-01	2	2	58
2026-03-01	2	3	90
2026-03-01	3	1	132
2026-03-01	3	2	48
2026-03-01	3	3	156
2026-03-01	4	1	132
2026-03-01	4	2	228
2026-03-01	4	3	145
2026-03-01	5	1	360
2026-03-01	5	2	288
2026-03-01	5	3	480
2026-03-01	6	1	321
2026-03-01	6	2	335
2026-03-01	6	3	0
2026-03-01	7	1	29
2026-03-01	7	2	32
2026-03-01	7	3	41
2026-03-01	8	1	34
2026-03-01	8	2	68
2026-03-01	8	3	69
2026-03-01	9	1	472
2026-03-01	9	2	304
2026-03-01	9	3	480
2026-03-01	10	1	120
2026-03-01	10	2	205
2026-03-01	10	3	223
2026-03-01	11	1	53
2026-03-01	11	2	34
2026-03-01	11	3	41
2026-03-01	12	1	530
2026-03-01	12	2	432
2026-03-01	12	3	205
2026-03-01	13	1	51
2026-03-01	13	2	86
2026-03-01	13	3	96
2026-03-01	14	1	108
2026-03-01	14	2	60
2026-03-01	14	3	63
2026-03-01	15	1	205
2026-03-01	15	2	110
2026-03-01	15	3	160
2026-03-01	16	1	270
2026-03-01	16	2	222
2026-03-01	16	3	339
2026-03-01	17	1	30
2026-03-01	17	2	71
2026-03-01	17	3	64
2026-03-01	18	1	368
2026-03-01	18	2	312
2026-03-01	18	3	432
2026-03-01	19	1	240
2026-03-01	19	2	46
2026-03-01	19	3	168
2026-03-01	20	1	110
2026-03-01	20	2	102
2026-03-01	20	3	84
2026-03-01	21	1	216
2026-03-01	21	2	96
2026-03-01	21	3	240
2026-03-01	22	1	91
2026-03-01	22	2	54
2026-03-01	22	3	79
2026-03-01	23	1	24
2026-03-01	23	2	156
2026-03-01	23	3	120
2026-03-01	24	1	276
2026-03-01	24	2	178
2026-03-01	24	3	351
2026-03-01	25	1	0
2026-03-01	25	2	24
2026-03-01	25	3	48
2026-03-01	26	1	111
2026-03-01	26	2	113
2026-03-01	26	3	164
2026-03-01	27	1	0
2026-03-01	27	2	137
2026-03-01	27	3	190
2026-03-01	28	1	160
2026-03-01	28	2	72
2026-03-01	28	3	55
2026-03-01	29	1	54
2026-03-01	29	2	137
2026-03-01	29	3	133
2026-03-01	30	1	351
2026-03-01	30	2	120
2026-03-01	30	3	513
2026-03-01	31	1	755
2026-03-01	31	2	192
2026-03-01	31	3	267
2026-03-01	32	1	17
2026-03-01	32	2	12
2026-03-01	32	3	42
2026-03-01	33	1	102
2026-03-01	33	2	66
2026-03-01	33	3	78
2026-03-01	34	1	84
2026-03-01	34	2	76
2026-03-01	34	3	12
2026-03-01	35	1	25
2026-03-01	35	2	60
2026-03-01	35	3	129
2026-03-01	36	1	251
2026-03-01	36	2	259
2026-03-01	36	3	177
2026-03-01	37	1	771
2026-03-01	37	2	421
2026-03-01	37	3	483
2026-03-01	38	1	312
2026-03-01	38	2	228
2026-03-01	38	3	114
2026-03-01	39	1	80
2026-03-01	39	2	130
2026-03-01	39	3	122
2026-03-01	40	1	35
2026-03-01	40	2	90
2026-03-01	40	3	66
2026-03-08	1	1	36
2026-03-08	1	2	54
2026-03-08	1	3	0
2026-03-08	2	1	60
2026-03-08	2	2	124
2026-03-08	2	3	54
2026-03-08	3	1	132
2026-03-08	3	2	156
2026-03-08	3	3	108
2026-03-08	4	1	132
2026-03-08	4	2	144
2026-03-08	4	3	85
2026-03-08	5	1	96
2026-03-08	5	2	216
2026-03-08	5	3	480
2026-03-08	6	1	225
2026-03-08	6	2	263
2026-03-08	6	3	216
2026-03-08	7	1	29
2026-03-08	7	2	44
2026-03-08	7	3	41
2026-03-08	8	1	58
2026-03-08	8	2	50
2026-03-08	8	3	33
2026-03-08	9	1	424
2026-03-08	9	2	304
2026-03-08	9	3	432
2026-03-08	10	1	120
2026-03-08	10	2	205
2026-03-08	10	3	223
2026-03-08	11	1	53
2026-03-08	11	2	70
2026-03-08	11	3	41
2026-03-08	12	1	314
2026-03-08	12	2	192
2026-03-08	12	3	565
2026-03-08	13	1	0
2026-03-08	13	2	2
2026-03-08	13	3	204
2026-03-08	14	1	108
2026-03-08	14	2	60
2026-03-08	14	3	87
2026-03-08	15	1	109
2026-03-08	15	2	182
2026-03-08	15	3	160
2026-03-08	16	1	210
2026-03-08	16	2	210
2026-03-08	16	3	279
2026-03-08	17	1	96
2026-03-08	17	2	71
2026-03-08	17	3	46
2026-03-08	18	1	368
2026-03-08	18	2	240
2026-03-08	18	3	360
2026-03-08	19	1	96
2026-03-08	19	2	46
2026-03-08	19	3	0
2026-03-08	20	1	104
2026-03-08	20	2	66
2026-03-08	20	3	42
2026-03-08	21	1	192
2026-03-08	21	2	216
2026-03-08	21	3	240
2026-03-08	22	1	85
2026-03-08	22	2	96
2026-03-08	22	3	61
2026-03-08	23	1	0
2026-03-08	23	2	108
2026-03-08	23	3	108
2026-03-08	24	1	12
2026-03-08	24	2	514
2026-03-08	24	3	231
2026-03-08	25	1	102
2026-03-08	25	2	96
2026-03-08	25	3	18
2026-03-08	26	1	93
2026-03-08	26	2	77
2026-03-08	26	3	146
2026-03-08	27	1	84
2026-03-08	27	2	233
2026-03-08	27	3	298
2026-03-08	28	1	160
2026-03-08	28	2	72
2026-03-08	28	3	55
2026-03-08	29	1	48
2026-03-08	29	2	107
2026-03-08	29	3	133
2026-03-08	30	1	351
2026-03-08	30	2	96
2026-03-08	30	3	705
2026-03-08	31	1	539
2026-03-08	31	2	480
2026-03-08	31	3	687
2026-03-08	32	1	17
2026-03-08	32	2	48
2026-03-08	32	3	30
2026-03-08	33	1	78
2026-03-08	33	2	48
2026-03-08	33	3	48
2026-03-08	34	1	36
2026-03-08	34	2	76
2026-03-08	34	3	84
2026-03-08	35	1	84
2026-03-08	35	2	60
2026-03-08	35	3	93
2026-03-08	36	1	179
2026-03-08	36	2	259
2026-03-08	36	3	153
2026-03-08	37	1	579
2026-03-08	37	2	205
2026-03-08	37	3	339
2026-03-08	38	1	240
2026-03-08	38	2	228
2026-03-08	38	3	222
2026-03-08	39	1	50
2026-03-08	39	2	106
2026-03-08	39	3	86
2026-03-08	40	1	53
2026-03-08	40	2	60
2026-03-08	40	3	66
2026-03-15	1	1	30
2026-03-15	1	2	36
2026-03-15	1	3	54
2026-03-15	2	1	96
2026-03-15	2	2	106
2026-03-15	2	3	150
2026-03-15	3	1	108
2026-03-15	3	2	132
2026-03-15	3	3	60
2026-03-15	4	1	96
2026-03-15	4	2	60
2026-03-15	4	3	0
2026-03-15	5	1	264
2026-03-15	5	2	168
2026-03-15	5	3	480
2026-03-15	6	1	489
2026-03-15	6	2	167
2026-03-15	6	3	120
2026-03-15	7	1	47
2026-03-15	7	2	26
2026-03-15	7	3	41
2026-03-15	8	1	0
2026-03-15	8	2	50
2026-03-15	8	3	15
2026-03-15	9	1	352
2026-03-15	9	2	256
2026-03-15	9	3	216
2026-03-15	10	1	120
2026-03-15	10	2	181
2026-03-15	10	3	223
2026-03-15	11	1	47
2026-03-15	11	2	70
2026-03-15	11	3	11
2026-03-15	12	1	146
2026-03-15	12	2	600
2026-03-15	12	3	277
2026-03-15	13	1	96
2026-03-15	13	2	74
2026-03-15	13	3	180
2026-03-15	14	1	72
2026-03-15	14	2	60
2026-03-15	14	3	63
2026-03-15	15	1	49
2026-03-15	15	2	182
2026-03-15	15	3	64
2026-03-15	16	1	354
2026-03-15	16	2	474
2026-03-15	16	3	147
2026-03-15	17	1	84
2026-03-15	17	2	47
2026-03-15	17	3	46
2026-03-15	18	1	368
2026-03-15	18	2	384
2026-03-15	18	3	336
2026-03-15	19	1	0
2026-03-15	19	2	46
2026-03-15	19	3	72
2026-03-15	20	1	98
2026-03-15	20	2	114
2026-03-15	20	3	108
2026-03-15	21	1	192
2026-03-15	21	2	168
2026-03-15	21	3	168
2026-03-15	22	1	85
2026-03-15	22	2	72
2026-03-15	22	3	61
2026-03-15	23	1	0
2026-03-15	23	2	96
2026-03-15	23	3	108
2026-03-15	24	1	276
2026-03-15	24	2	514
2026-03-15	24	3	135
2026-03-15	25	1	72
2026-03-15	25	2	90
2026-03-15	25	3	0
2026-03-15	26	1	189
2026-03-15	26	2	143
2026-03-15	26	3	254
2026-03-15	27	1	36
2026-03-15	27	2	209
2026-03-15	27	3	298
2026-03-15	28	1	136
2026-03-15	28	2	48
2026-03-15	28	3	19
2026-03-15	29	1	108
2026-03-15	29	2	143
2026-03-15	29	3	133
2026-03-15	30	1	591
2026-03-15	30	2	288
2026-03-15	30	3	705
2026-03-15	31	1	227
2026-03-15	31	2	456
2026-03-15	31	3	351
2026-03-15	32	1	59
2026-03-15	32	2	48
2026-03-15	32	3	12
2026-03-15	33	1	42
2026-03-15	33	2	120
2026-03-15	33	3	96
2026-03-15	34	1	36
2026-03-15	34	2	76
2026-03-15	34	3	84
2026-03-15	35	1	84
2026-03-15	35	2	132
2026-03-15	35	3	81
2026-03-15	36	1	179
2026-03-15	36	2	187
2026-03-15	36	3	153
2026-03-15	37	1	459
2026-03-15	37	2	733
2026-03-15	37	3	195
2026-03-15	38	1	204
2026-03-15	38	2	228
2026-03-15	38	3	126
2026-03-15	39	1	116
2026-03-15	39	2	100
2026-03-15	39	3	62
2026-03-15	40	1	41
2026-03-15	40	2	60
2026-03-15	40	3	66
2026-03-22	1	1	60
2026-03-22	1	2	66
2026-03-22	1	3	36
2026-03-22	2	1	78
2026-03-22	2	2	76
2026-03-22	2	3	132
2026-03-22	3	1	108
2026-03-22	3	2	72
2026-03-22	3	3	0
2026-03-22	4	1	180
2026-03-22	4	2	228
2026-03-22	4	3	108
2026-03-22	5	1	264
2026-03-22	5	2	456
2026-03-22	5	3	408
2026-03-22	6	1	321
2026-03-22	6	2	455
2026-03-22	6	3	360
2026-03-22	7	1	47
2026-03-22	7	2	20
2026-03-22	7	3	0
2026-03-22	8	1	0
2026-03-22	8	2	104
2026-03-22	8	3	0
2026-03-22	9	1	280
2026-03-22	9	2	208
2026-03-22	9	3	456
2026-03-22	10	1	120
2026-03-22	10	2	181
2026-03-22	10	3	127
2026-03-22	11	1	47
2026-03-22	11	2	70
2026-03-22	11	3	53
2026-03-22	12	1	506
2026-03-22	12	2	432
2026-03-22	12	3	133
2026-03-22	13	1	60
2026-03-22	13	2	0
2026-03-22	13	3	96
2026-03-22	14	1	0
2026-03-22	14	2	144
2026-03-22	14	3	27
2026-03-22	15	1	0
2026-03-22	15	2	134
2026-03-22	15	3	100
2026-03-22	16	1	306
2026-03-22	16	2	450
2026-03-22	16	3	75
2026-03-22	17	1	84
2026-03-22	17	2	95
2026-03-22	17	3	82
2026-03-22	18	1	368
2026-03-22	18	2	384
2026-03-22	18	3	192
2026-03-22	19	1	192
2026-03-22	19	2	262
2026-03-22	19	3	216
2026-03-22	20	1	170
2026-03-22	20	2	72
2026-03-22	20	3	72
2026-03-22	21	1	192
2026-03-22	21	2	144
2026-03-22	21	3	48
2026-03-22	22	1	79
2026-03-22	22	2	72
2026-03-22	22	3	43
2026-03-22	23	1	132
2026-03-22	23	2	84
2026-03-22	23	3	48
2026-03-22	24	1	228
2026-03-22	24	2	370
2026-03-22	24	3	327
2026-03-22	25	1	66
2026-03-22	25	2	72
2026-03-22	25	3	0
2026-03-22	26	1	171
2026-03-22	26	2	125
2026-03-22	26	3	254
2026-03-22	27	1	36
2026-03-22	27	2	161
2026-03-22	27	3	298
2026-03-22	28	1	136
2026-03-22	28	2	12
2026-03-22	28	3	19
2026-03-22	29	1	102
2026-03-22	29	2	125
2026-03-22	29	3	205
2026-03-22	30	1	519
2026-03-22	30	2	192
2026-03-22	30	3	633
2026-03-22	31	1	155
2026-03-22	31	2	120
2026-03-22	31	3	231
2026-03-22	32	1	59
2026-03-22	32	2	48
2026-03-22	32	3	42
2026-03-22	33	1	36
2026-03-22	33	2	102
2026-03-22	33	3	54
2026-03-22	34	1	96
2026-03-22	34	2	76
2026-03-22	34	3	84
2026-03-22	35	1	72
2026-03-22	35	2	108
2026-03-22	35	3	81
2026-03-22	36	1	179
2026-03-22	36	2	67
2026-03-22	36	3	153
2026-03-22	37	1	387
2026-03-22	37	2	637
2026-03-22	37	3	0
2026-03-22	38	1	144
2026-03-22	38	2	132
2026-03-22	38	3	78
2026-03-22	39	1	86
2026-03-22	39	2	40
2026-03-22	39	3	146
2026-03-22	40	1	41
2026-03-22	40	2	42
2026-03-22	40	3	48
2026-03-29	1	1	24
2026-03-29	1	2	36
2026-03-29	1	3	0
2026-03-29	2	1	66
2026-03-29	2	2	46
2026-03-29	2	3	72
2026-03-29	3	1	84
2026-03-29	3	2	0
2026-03-29	3	3	60
2026-03-29	4	1	108
2026-03-29	4	2	180
2026-03-29	4	3	96
2026-03-29	5	1	360
2026-03-29	5	2	456
2026-03-29	5	3	384
2026-03-29	6	1	225
2026-03-29	6	2	455
2026-03-29	6	3	72
2026-03-29	7	1	47
2026-03-29	7	2	56
2026-03-29	7	3	0
2026-03-29	8	1	36
2026-03-29	8	2	98
2026-03-29	8	3	54
2026-03-29	9	1	136
2026-03-29	9	2	448
2026-03-29	9	3	168
2026-03-29	10	1	96
2026-03-29	10	2	109
2026-03-29	10	3	79
2026-03-29	11	1	41
2026-03-29	11	2	70
2026-03-29	11	3	35
2026-03-29	12	1	314
2026-03-29	12	2	384
2026-03-29	12	3	589
2026-03-29	13	1	12
2026-03-29	13	2	0
2026-03-29	13	3	72
2026-03-29	14	1	84
2026-03-29	14	2	144
2026-03-29	14	3	99
2026-03-29	15	1	96
2026-03-29	15	2	98
2026-03-29	15	3	88
2026-03-29	16	1	234
2026-03-29	16	2	450
2026-03-29	16	3	327
2026-03-29	17	1	72
2026-03-29	17	2	77
2026-03-29	17	3	64
2026-03-29	18	1	224
2026-03-29	18	2	384
2026-03-29	18	3	144
2026-03-29	19	1	72
2026-03-29	19	2	214
2026-03-29	19	3	168
2026-03-29	20	1	152
2026-03-29	20	2	54
2026-03-29	20	3	72
2026-03-29	21	1	120
2026-03-29	21	2	48
2026-03-29	21	3	0
2026-03-29	22	1	73
2026-03-29	22	2	72
2026-03-29	22	3	37
2026-03-29	23	1	132
2026-03-29	23	2	72
2026-03-29	23	3	0
2026-03-29	24	1	468
2026-03-29	24	2	370
2026-03-29	24	3	207
2026-03-29	25	1	30
2026-03-29	25	2	66
2026-03-29	25	3	90
2026-03-29	26	1	129
2026-03-29	26	2	65
2026-03-29	26	3	254
2026-03-29	27	1	36
2026-03-29	27	2	101
2026-03-29	27	3	298
2026-03-29	28	1	184
2026-03-29	28	2	12
2026-03-29	28	3	19
2026-03-29	29	1	102
2026-03-29	29	2	101
2026-03-29	29	3	199
2026-03-29	30	1	447
2026-03-29	30	2	192
2026-03-29	30	3	585
2026-03-29	31	1	467
2026-03-29	31	2	624
2026-03-29	31	3	0
2026-03-29	32	1	59
2026-03-29	32	2	42
2026-03-29	32	3	18
2026-03-29	33	1	108
2026-03-29	33	2	90
2026-03-29	33	3	24
2026-03-29	34	1	48
2026-03-29	34	2	64
2026-03-29	34	3	84
2026-03-29	35	1	36
2026-03-29	35	2	72
2026-03-29	35	3	81
2026-03-29	36	1	107
2026-03-29	36	2	240
2026-03-29	36	3	33
2026-03-29	37	1	291
2026-03-29	37	2	541
2026-03-29	37	3	360
2026-03-29	38	1	84
2026-03-29	38	2	84
2026-03-29	38	3	222
2026-03-29	39	1	80
2026-03-29	39	2	28
2026-03-29	39	3	128
2026-03-29	40	1	89
2026-03-29	40	2	54
2026-03-29	40	3	30
2026-04-05	1	1	78
2026-04-05	1	2	84
2026-04-05	1	3	42
2026-04-05	2	1	36
2026-04-05	2	2	106
2026-04-05	2	3	18
2026-04-05	3	1	84
2026-04-05	3	2	72
2026-04-05	3	3	144
2026-04-05	4	1	180
2026-04-05	4	2	144
2026-04-05	4	3	228
2026-04-05	5	1	336
2026-04-05	5	2	384
2026-04-05	5	3	264
2026-04-05	6	1	465
2026-04-05	6	2	455
2026-04-05	6	3	0
2026-04-05	7	1	47
2026-04-05	7	2	50
2026-04-05	7	3	24
2026-04-05	8	1	60
2026-04-05	8	2	92
2026-04-05	8	3	36
2026-04-05	9	1	64
2026-04-05	9	2	352
2026-04-05	9	3	24
2026-04-05	10	1	96
2026-04-05	10	2	109
2026-04-05	10	3	7
2026-04-05	11	1	41
2026-04-05	11	2	70
2026-04-05	11	3	17
2026-04-05	12	1	698
2026-04-05	12	2	288
2026-04-05	12	3	349
2026-04-05	13	1	62
2026-04-05	13	2	24
2026-04-05	13	3	72
2026-04-05	14	1	60
2026-04-05	14	2	132
2026-04-05	14	3	39
2026-04-05	15	1	72
2026-04-05	15	2	230
2026-04-05	15	3	52
2026-04-05	16	1	186
2026-04-05	16	2	438
2026-04-05	16	3	219
2026-04-05	17	1	72
2026-04-05	17	2	65
2026-04-05	17	3	46
2026-04-05	18	1	152
2026-04-05	18	2	360
2026-04-05	18	3	144
2026-04-05	19	1	240
2026-04-05	19	2	142
2026-04-05	19	3	96
2026-04-05	20	1	146
2026-04-05	20	2	54
2026-04-05	20	3	42
2026-04-05	21	1	48
2026-04-05	21	2	0
2026-04-05	21	3	192
2026-04-05	22	1	73
2026-04-05	22	2	72
2026-04-05	22	3	103
2026-04-05	23	1	120
2026-04-05	23	2	72
2026-04-05	23	3	0
2026-04-05	24	1	396
2026-04-05	24	2	346
2026-04-05	24	3	87
2026-04-05	25	1	18
2026-04-05	25	2	66
2026-04-05	25	3	90
2026-04-05	26	1	123
2026-04-05	26	2	41
2026-04-05	26	3	254
2026-04-05	27	1	36
2026-04-05	27	2	65
2026-04-05	27	3	274
2026-04-05	28	1	184
2026-04-05	28	2	60
2026-04-05	28	3	67
2026-04-05	29	1	102
2026-04-05	29	2	95
2026-04-05	29	3	199
2026-04-05	30	1	375
2026-04-05	30	2	24
2026-04-05	30	3	585
2026-04-05	31	1	395
2026-04-05	31	2	600
2026-04-05	31	3	456
2026-04-05	32	1	59
2026-04-05	32	2	42
2026-04-05	32	3	18
2026-04-05	33	1	108
2026-04-05	33	2	72
2026-04-05	33	3	54
2026-04-05	34	1	48
2026-04-05	34	2	64
2026-04-05	34	3	48
2026-04-05	35	1	132
2026-04-05	35	2	48
2026-04-05	35	3	45
2026-04-05	36	1	0
2026-04-05	36	2	240
2026-04-05	36	3	33
2026-04-05	37	1	699
2026-04-05	37	2	541
2026-04-05	37	3	192
2026-04-05	38	1	264
2026-04-05	38	2	276
2026-04-05	38	3	186
2026-04-05	39	1	152
2026-04-05	39	2	94
2026-04-05	39	3	122
2026-04-05	40	1	83
2026-04-05	40	2	54
2026-04-05	40	3	60
2026-04-12	1	1	48
2026-04-12	1	2	72
2026-04-12	1	3	42
2026-04-12	2	1	78
2026-04-12	2	2	64
2026-04-12	2	3	18
2026-04-12	3	1	156
2026-04-12	3	2	132
2026-04-12	3	3	48
2026-04-12	4	1	108
2026-04-12	4	2	36
2026-04-12	4	3	72
2026-04-12	5	1	336
2026-04-12	5	2	264
2026-04-12	5	3	168
2026-04-12	6	1	297
2026-04-12	6	2	287
2026-04-12	6	3	0
2026-04-12	7	1	47
2026-04-12	7	2	50
2026-04-12	7	3	18
2026-04-12	8	1	42
2026-04-12	8	2	68
2026-04-12	8	3	72
2026-04-12	9	1	0
2026-04-12	9	2	280
2026-04-12	9	3	24
2026-04-12	10	1	96
2026-04-12	10	2	37
2026-04-12	10	3	7
2026-04-12	11	1	41
2026-04-12	11	2	52
2026-04-12	11	3	53
2026-04-12	12	1	602
2026-04-12	12	2	648
2026-04-12	12	3	229
2026-04-12	13	1	38
2026-04-12	13	2	108
2026-04-12	13	3	36
2026-04-12	14	1	132
2026-04-12	14	2	108
2026-04-12	14	3	3
2026-04-12	15	1	156
2026-04-12	15	2	218
2026-04-12	15	3	160
2026-04-12	16	1	474
2026-04-12	16	2	402
2026-04-12	16	3	123
2026-04-12	17	1	54
2026-04-12	17	2	59
2026-04-12	17	3	40
2026-04-12	18	1	152
2026-04-12	18	2	360
2026-04-12	18	3	288
2026-04-12	19	1	168
2026-04-12	19	2	142
2026-04-12	19	3	24
2026-04-12	20	1	116
2026-04-12	20	2	120
2026-04-12	20	3	102
2026-04-12	21	1	0
2026-04-12	21	2	0
2026-04-12	21	3	120
2026-04-12	22	1	73
2026-04-12	22	2	42
2026-04-12	22	3	103
2026-04-12	23	1	84
2026-04-12	23	2	36
2026-04-12	23	3	144
2026-04-12	24	1	204
2026-04-12	24	2	274
2026-04-12	24	3	279
2026-04-12	25	1	0
2026-04-12	25	2	30
2026-04-12	25	3	90
2026-04-12	26	1	99
2026-04-12	26	2	5
2026-04-12	26	3	254
2026-04-12	27	1	0
2026-04-12	27	2	53
2026-04-12	27	3	274
2026-04-12	28	1	184
2026-04-12	28	2	60
2026-04-12	28	3	67
2026-04-12	29	1	102
2026-04-12	29	2	83
2026-04-12	29	3	199
2026-04-12	30	1	375
2026-04-12	30	2	0
2026-04-12	30	3	585
2026-04-12	31	1	659
2026-04-12	31	2	480
2026-04-12	31	3	384
2026-04-12	32	1	47
2026-04-12	32	2	24
2026-04-12	32	3	42
2026-04-12	33	1	90
2026-04-12	33	2	42
2026-04-12	33	3	54
2026-04-12	34	1	96
2026-04-12	34	2	64
2026-04-12	34	3	48
2026-04-12	35	1	132
2026-04-12	35	2	36
2026-04-12	35	3	81
2026-04-12	36	1	130
2026-04-12	36	2	240
2026-04-12	36	3	177
2026-04-12	37	1	603
2026-04-12	37	2	469
2026-04-12	37	3	696
2026-04-12	38	1	204
2026-04-12	38	2	204
2026-04-12	38	3	102
2026-04-12	39	1	140
2026-04-12	39	2	64
2026-04-12	39	3	80
2026-04-12	40	1	83
2026-04-12	40	2	54
2026-04-12	40	3	60
2026-04-19	1	1	48
2026-04-19	1	2	72
2026-04-19	1	3	84
2026-04-19	2	1	18
2026-04-19	2	2	64
2026-04-19	2	3	72
2026-04-19	3	1	132
2026-04-19	3	2	132
2026-04-19	3	3	36
2026-04-19	4	1	204
2026-04-19	4	2	151
2026-04-19	4	3	24
2026-04-19	5	1	72
2026-04-19	5	2	48
2026-04-19	5	3	408
2026-04-19	6	1	201
2026-04-19	6	2	263
2026-04-19	6	3	0
2026-04-19	7	1	47
2026-04-19	7	2	26
2026-04-19	7	3	48
2026-04-19	8	1	30
2026-04-19	8	2	50
2026-04-19	8	3	72
2026-04-19	9	1	0
2026-04-19	9	2	280
2026-04-19	9	3	0
2026-04-19	10	1	96
2026-04-19	10	2	37
2026-04-19	10	3	7
2026-04-19	11	1	41
2026-04-19	11	2	52
2026-04-19	11	3	47
2026-04-19	12	1	506
2026-04-19	12	2	408
2026-04-19	12	3	181
2026-04-19	13	1	134
2026-04-19	13	2	72
2026-04-19	13	3	120
2026-04-19	14	1	108
2026-04-19	14	2	72
2026-04-19	14	3	0
2026-04-19	15	1	156
2026-04-19	15	2	182
2026-04-19	15	3	100
2026-04-19	16	1	414
2026-04-19	16	2	342
2026-04-19	16	3	279
2026-04-19	17	1	54
2026-04-19	17	2	17
2026-04-19	17	3	94
2026-04-19	18	1	152
2026-04-19	18	2	240
2026-04-19	18	3	168
2026-04-19	19	1	168
2026-04-19	19	2	214
2026-04-19	19	3	72
2026-04-19	20	1	98
2026-04-19	20	2	120
2026-04-19	20	3	78
2026-04-19	21	1	192
2026-04-19	21	2	240
2026-04-19	21	3	0
2026-04-19	22	1	73
2026-04-19	22	2	42
2026-04-19	22	3	85
2026-04-19	23	1	84
2026-04-19	23	2	108
2026-04-19	23	3	144
2026-04-19	24	1	180
2026-04-19	24	2	274
2026-04-19	24	3	207
2026-04-19	25	1	36
2026-04-19	25	2	6
2026-04-19	25	3	66
2026-04-19	26	1	183
2026-04-19	26	2	108
2026-04-19	26	3	254
2026-04-19	27	1	132
2026-04-19	27	2	173
2026-04-19	27	3	406
2026-04-19	28	1	172
2026-04-19	28	2	60
2026-04-19	28	3	67
2026-04-19	29	1	78
2026-04-19	29	2	77
2026-04-19	29	3	199
2026-04-19	30	1	375
2026-04-19	30	2	264
2026-04-19	30	3	849
2026-04-19	31	1	491
2026-04-19	31	2	840
2026-04-19	31	3	696
2026-04-19	32	1	47
2026-04-19	32	2	24
2026-04-19	32	3	24
2026-04-19	33	1	72
2026-04-19	33	2	108
2026-04-19	33	3	144
2026-04-19	34	1	60
2026-04-19	34	2	64
2026-04-19	34	3	96
2026-04-19	35	1	132
2026-04-19	35	2	120
2026-04-19	35	3	33
2026-04-19	36	1	226
2026-04-19	36	2	240
2026-04-19	36	3	57
2026-04-19	37	1	507
2026-04-19	37	2	277
2026-04-19	37	3	408
2026-04-19	38	1	132
2026-04-19	38	2	180
2026-04-19	38	3	90
2026-04-19	39	1	98
2026-04-19	39	2	148
2026-04-19	39	3	62
2026-04-19	40	1	71
2026-04-19	40	2	54
2026-04-19	40	3	54
2026-04-26	1	1	30
2026-04-26	1	2	72
2026-04-26	1	3	84
2026-04-26	2	1	0
2026-04-26	2	2	154
2026-04-26	2	3	54
2026-04-26	3	1	96
2026-04-26	3	2	108
2026-04-26	3	3	156
2026-04-26	4	1	180
2026-04-26	4	2	151
2026-04-26	4	3	96
2026-04-26	5	1	240
2026-04-26	5	2	264
2026-04-26	5	3	288
2026-04-26	6	1	177
2026-04-26	6	2	239
2026-04-26	6	3	0
2026-04-26	7	1	35
2026-04-26	7	2	26
2026-04-26	7	3	42
2026-04-26	8	1	24
2026-04-26	8	2	50
2026-04-26	8	3	54
2026-04-26	9	1	336
2026-04-26	9	2	280
2026-04-26	9	3	0
2026-04-26	10	1	216
2026-04-26	10	2	133
2026-04-26	10	3	151
2026-04-26	11	1	41
2026-04-26	11	2	34
2026-04-26	11	3	47
2026-04-26	12	1	314
2026-04-26	12	2	336
2026-04-26	12	3	493
2026-04-26	13	1	62
2026-04-26	13	2	168
2026-04-26	13	3	120
2026-04-26	14	1	108
2026-04-26	14	2	48
2026-04-26	14	3	84
2026-04-26	15	1	132
2026-04-26	15	2	170
2026-04-26	15	3	28
2026-04-26	16	1	330
2026-04-26	16	2	318
2026-04-26	16	3	255
2026-04-26	17	1	29
2026-04-26	17	2	71
2026-04-26	17	3	82
2026-04-26	18	1	368
2026-04-26	18	2	240
2026-04-26	18	3	384
2026-04-26	19	1	168
2026-04-26	19	2	214
2026-04-26	19	3	72
2026-04-26	20	1	98
2026-04-26	20	2	120
2026-04-26	20	3	54
2026-04-26	21	1	192
2026-04-26	21	2	144
2026-04-26	21	3	0
2026-04-26	22	1	31
2026-04-26	22	2	108
2026-04-26	22	3	49
2026-04-26	23	1	60
2026-04-26	23	2	108
2026-04-26	23	3	132
2026-04-26	24	1	132
2026-04-26	24	2	514
2026-04-26	24	3	423
2026-04-26	25	1	12
2026-04-26	25	2	6
2026-04-26	25	3	60
2026-04-26	26	1	165
2026-04-26	26	2	108
2026-04-26	26	3	362
2026-04-26	27	1	120
2026-04-26	27	2	161
2026-04-26	27	3	406
2026-04-26	28	1	172
2026-04-26	28	2	60
2026-04-26	28	3	67
2026-04-26	29	1	78
2026-04-26	29	2	41
2026-04-26	29	3	199
2026-04-26	30	1	615
2026-04-26	30	2	144
2026-04-26	30	3	849
2026-04-26	31	1	347
2026-04-26	31	2	816
2026-04-26	31	3	528
2026-04-26	32	1	47
2026-04-26	32	2	60
2026-04-26	32	3	12
2026-04-26	33	1	42
2026-04-26	33	2	108
2026-04-26	33	3	144
2026-04-26	34	1	48
2026-04-26	34	2	64
2026-04-26	34	3	96
2026-04-26	35	1	96
2026-04-26	35	2	120
2026-04-26	35	3	117
2026-04-26	36	1	226
2026-04-26	36	2	240
2026-04-26	36	3	57
2026-04-26	37	1	339
2026-04-26	37	2	757
2026-04-26	37	3	288
2026-04-26	38	1	72
2026-04-26	38	2	180
2026-04-26	38	3	246
2026-04-26	39	1	86
2026-04-26	39	2	136
2026-04-26	39	3	152
2026-04-26	40	1	71
2026-04-26	40	2	96
2026-04-26	40	3	78
2026-05-03	1	1	84
2026-05-03	1	2	60
2026-05-03	1	3	66
2026-05-03	2	1	0
2026-05-03	2	2	154
2026-05-03	2	3	120
2026-05-03	3	1	48
2026-05-03	3	2	84
2026-05-03	3	3	108
2026-05-03	4	1	168
2026-05-03	4	2	103
2026-05-03	4	3	264
2026-05-03	5	1	168
2026-05-03	5	2	240
2026-05-03	5	3	288
2026-05-03	6	1	177
2026-05-03	6	2	239
2026-05-03	6	3	384
2026-05-03	7	1	35
2026-05-03	7	2	26
2026-05-03	7	3	42
2026-05-03	8	1	24
2026-05-03	8	2	38
2026-05-03	8	3	18
2026-05-03	9	1	336
2026-05-03	9	2	256
2026-05-03	9	3	312
2026-05-03	10	1	144
2026-05-03	10	2	133
2026-05-03	10	3	103
2026-05-03	11	1	41
2026-05-03	11	2	34
2026-05-03	11	3	47
2026-05-03	12	1	242
2026-05-03	12	2	336
2026-05-03	12	3	469
2026-05-03	13	1	146
2026-05-03	13	2	168
2026-05-03	13	3	108
2026-05-03	14	1	72
2026-05-03	14	2	12
2026-05-03	14	3	156
2026-05-03	15	1	240
2026-05-03	15	2	158
2026-05-03	15	3	148
2026-05-03	16	1	270
2026-05-03	16	2	270
2026-05-03	16	3	123
2026-05-03	17	1	95
2026-05-03	17	2	59
2026-05-03	17	3	82
2026-05-03	18	1	368
2026-05-03	18	2	456
2026-05-03	18	3	384
2026-05-03	19	1	168
2026-05-03	19	2	214
2026-05-03	19	3	168
2026-05-03	20	1	92
2026-05-03	20	2	114
2026-05-03	20	3	126
2026-05-03	21	1	192
2026-05-03	21	2	144
2026-05-03	21	3	168
2026-05-03	22	1	91
2026-05-03	22	2	96
2026-05-03	22	3	49
2026-05-03	23	1	48
2026-05-03	23	2	36
2026-05-03	23	3	96
2026-05-03	24	1	348
2026-05-03	24	2	418
2026-05-03	24	3	351
2026-05-03	25	1	12
2026-05-03	25	2	78
2026-05-03	25	3	48
2026-05-03	26	1	165
2026-05-03	26	2	90
2026-05-03	26	3	362
2026-05-03	27	1	96
2026-05-03	27	2	137
2026-05-03	27	3	406
2026-05-03	28	1	172
2026-05-03	28	2	36
2026-05-03	28	3	67
2026-05-03	29	1	78
2026-05-03	29	2	23
2026-05-03	29	3	199
2026-05-03	30	1	615
2026-05-03	30	2	144
2026-05-03	30	3	849
2026-05-03	31	1	323
2026-05-03	31	2	816
2026-05-03	31	3	360
2026-05-03	32	1	35
2026-05-03	32	2	60
2026-05-03	32	3	30
2026-05-03	33	1	36
2026-05-03	33	2	108
2026-05-03	33	3	126
2026-05-03	34	1	96
2026-05-03	34	2	64
2026-05-03	34	3	60
2026-05-03	35	1	96
2026-05-03	35	2	84
2026-05-03	35	3	117
2026-05-03	36	1	226
2026-05-03	36	2	216
2026-05-03	36	3	177
2026-05-03	37	1	219
2026-05-03	37	2	685
2026-05-03	37	3	720
2026-05-03	38	1	204
2026-05-03	38	2	348
2026-05-03	38	3	246
2026-05-03	39	1	62
2026-05-03	39	2	100
2026-05-03	39	3	134
2026-05-03	40	1	71
2026-05-03	40	2	78
2026-05-03	40	3	60
2026-05-10	1	1	48
2026-05-10	1	2	48
2026-05-10	1	3	54
2026-05-10	2	1	96
2026-05-10	2	2	142
2026-05-10	2	3	120
2026-05-10	3	1	84
2026-05-10	3	2	60
2026-05-10	3	3	60
2026-05-10	4	1	36
2026-05-10	4	2	67
2026-05-10	4	3	264
2026-05-10	5	1	432
2026-05-10	5	2	384
2026-05-10	5	3	168
2026-05-10	6	1	57
2026-05-10	6	2	167
2026-05-10	6	3	240
2026-05-10	7	1	17
2026-05-10	7	2	26
2026-05-10	7	3	42
2026-05-10	8	1	0
2026-05-10	8	2	32
2026-05-10	8	3	0
2026-05-10	9	1	288
2026-05-10	9	2	208
2026-05-10	9	3	168
2026-05-10	10	1	120
2026-05-10	10	2	109
2026-05-10	10	3	55
2026-05-10	11	1	41
2026-05-10	11	2	64
2026-05-10	11	3	47
2026-05-10	12	1	482
2026-05-10	12	2	120
2026-05-10	12	3	301
2026-05-10	13	1	110
2026-05-10	13	2	156
2026-05-10	13	3	180
2026-05-10	14	1	72
2026-05-10	14	2	84
2026-05-10	14	3	120
2026-05-10	15	1	144
2026-05-10	15	2	158
2026-05-10	15	3	100
2026-05-10	16	1	234
2026-05-10	16	2	486
2026-05-10	16	3	351
2026-05-10	17	1	89
2026-05-10	17	2	59
2026-05-10	17	3	64
2026-05-10	18	1	320
2026-05-10	18	2	432
2026-05-10	18	3	216
2026-05-10	19	1	168
2026-05-10	19	2	214
2026-05-10	19	3	168
2026-05-10	20	1	158
2026-05-10	20	2	114
2026-05-10	20	3	114
2026-05-10	21	1	192
2026-05-10	21	2	72
2026-05-10	21	3	120
2026-05-10	22	1	91
2026-05-10	22	2	90
2026-05-10	22	3	109
2026-05-10	23	1	12
2026-05-10	23	2	36
2026-05-10	23	3	24
2026-05-10	24	1	348
2026-05-10	24	2	370
2026-05-10	24	3	327
2026-05-10	25	1	54
2026-05-10	25	2	78
2026-05-10	25	3	30
2026-05-10	26	1	165
2026-05-10	26	2	48
2026-05-10	26	3	362
2026-05-10	27	1	60
2026-05-10	27	2	125
2026-05-10	27	3	382
2026-05-10	28	1	172
2026-05-10	28	2	36
2026-05-10	28	3	67
2026-05-10	29	1	66
2026-05-10	29	2	77
2026-05-10	29	3	199
2026-05-10	30	1	567
2026-05-10	30	2	0
2026-05-10	30	3	825
2026-05-10	31	1	707
2026-05-10	31	2	744
2026-05-10	31	3	192
2026-05-10	32	1	5
2026-05-10	32	2	54
2026-05-10	32	3	12
2026-05-10	33	1	102
2026-05-10	33	2	108
2026-05-10	33	3	126
2026-05-10	34	1	60
2026-05-10	34	2	64
2026-05-10	34	3	48
2026-05-10	35	1	84
2026-05-10	35	2	84
2026-05-10	35	3	81
2026-05-10	36	1	226
2026-05-10	36	2	120
2026-05-10	36	3	105
2026-05-10	37	1	747
2026-05-10	37	2	685
2026-05-10	37	3	600
2026-05-10	38	1	168
2026-05-10	38	2	336
2026-05-10	38	3	198
2026-05-10	39	1	62
2026-05-10	39	2	82
2026-05-10	39	3	134
2026-05-10	40	1	71
2026-05-10	40	2	78
2026-05-10	40	3	42
2026-05-17	1	1	36
2026-05-17	1	2	30
2026-05-17	1	3	42
2026-05-17	2	1	186
2026-05-17	2	2	94
2026-05-17	2	3	102
2026-05-17	3	1	72
2026-05-17	3	2	168
2026-05-17	3	3	12
2026-05-17	4	1	156
2026-05-17	4	2	235
2026-05-17	4	3	204
2026-05-17	5	1	360
2026-05-17	5	2	312
2026-05-17	5	3	168
2026-05-17	6	1	9
2026-05-17	6	2	431
2026-05-17	6	3	192
2026-05-17	7	1	17
2026-05-17	7	2	20
2026-05-17	7	3	42
2026-05-17	8	1	66
2026-05-17	8	2	80
2026-05-17	8	3	0
2026-05-17	9	1	288
2026-05-17	9	2	160
2026-05-17	9	3	168
2026-05-17	10	1	96
2026-05-17	10	2	109
2026-05-17	10	3	55
2026-05-17	11	1	17
2026-05-17	11	2	52
2026-05-17	11	3	35
2026-05-17	12	1	386
2026-05-17	12	2	480
2026-05-17	12	3	589
2026-05-17	13	1	50
2026-05-17	13	2	144
2026-05-17	13	3	156
2026-05-17	14	1	72
2026-05-17	14	2	24
2026-05-17	14	3	36
2026-05-17	15	1	144
2026-05-17	15	2	122
2026-05-17	15	3	28
2026-05-17	16	1	450
2026-05-17	16	2	414
2026-05-17	16	3	291
2026-05-17	17	1	71
2026-05-17	17	2	41
2026-05-17	17	3	64
2026-05-17	18	1	248
2026-05-17	18	2	432
2026-05-17	18	3	144
2026-05-17	19	1	168
2026-05-17	19	2	214
2026-05-17	19	3	96
2026-05-17	20	1	158
2026-05-17	20	2	114
2026-05-17	20	3	114
2026-05-17	21	1	192
2026-05-17	21	2	72
2026-05-17	21	3	72
2026-05-17	22	1	73
2026-05-17	22	2	72
2026-05-17	22	3	109
2026-05-17	23	1	0
2026-05-17	23	2	36
2026-05-17	23	3	0
2026-05-17	24	1	348
2026-05-17	24	2	298
2026-05-17	24	3	303
2026-05-17	25	1	42
2026-05-17	25	2	78
2026-05-17	25	3	18
2026-05-17	26	1	153
2026-05-17	26	2	12
2026-05-17	26	3	362
2026-05-17	27	1	24
2026-05-17	27	2	53
2026-05-17	27	3	382
2026-05-17	28	1	172
2026-05-17	28	2	36
2026-05-17	28	3	67
2026-05-17	29	1	126
2026-05-17	29	2	47
2026-05-17	29	3	271
2026-05-17	30	1	567
2026-05-17	30	2	0
2026-05-17	30	3	825
2026-05-17	31	1	491
2026-05-17	31	2	504
2026-05-17	31	3	528
2026-05-17	32	1	5
2026-05-17	32	2	48
2026-05-17	32	3	42
2026-05-17	33	1	60
2026-05-17	33	2	108
2026-05-17	33	3	84
2026-05-17	34	1	60
2026-05-17	34	2	40
2026-05-17	34	3	48
2026-05-17	35	1	72
2026-05-17	35	2	84
2026-05-17	35	3	69
2026-05-17	36	1	226
2026-05-17	36	2	48
2026-05-17	36	3	105
2026-05-17	37	1	675
2026-05-17	37	2	637
2026-05-17	37	3	600
2026-05-17	38	1	84
2026-05-17	38	2	276
2026-05-17	38	3	114
2026-05-17	39	1	116
2026-05-17	39	2	64
2026-05-17	39	3	92
2026-05-17	40	1	65
2026-05-17	40	2	78
2026-05-17	40	3	24
2026-05-24	1	1	48
2026-05-24	1	2	60
2026-05-24	1	3	78
2026-05-24	2	1	156
2026-05-24	2	2	58
2026-05-24	2	3	72
2026-05-24	3	1	180
2026-05-24	3	2	108
2026-05-24	3	3	120
2026-05-24	4	1	144
2026-05-24	4	2	199
2026-05-24	4	3	168
2026-05-24	5	1	264
2026-05-24	5	2	240
2026-05-24	5	3	360
2026-05-24	6	1	225
2026-05-24	6	2	383
2026-05-24	6	3	0
2026-05-24	7	1	17
2026-05-24	7	2	39
2026-05-24	7	3	42
2026-05-24	8	1	54
2026-05-24	8	2	44
2026-05-24	8	3	54
2026-05-24	9	1	264
2026-05-24	9	2	64
2026-05-24	9	3	120
2026-05-24	10	1	48
2026-05-24	10	2	85
2026-05-24	10	3	0
2026-05-24	11	1	0
2026-05-24	11	2	52
2026-05-24	11	3	17
2026-05-24	12	1	194
2026-05-24	12	2	312
2026-05-24	12	3	445
2026-05-24	13	1	110
2026-05-24	13	2	182
2026-05-24	13	3	84
2026-05-24	14	1	132
2026-05-24	14	2	0
2026-05-24	14	3	0
2026-05-24	15	1	144
2026-05-24	15	2	242
2026-05-24	15	3	124
2026-05-24	16	1	402
2026-05-24	16	2	354
2026-05-24	16	3	219
2026-05-24	17	1	59
2026-05-24	17	2	41
2026-05-24	17	3	64
2026-05-24	18	1	211
2026-05-24	18	2	432
2026-05-24	18	3	144
2026-05-24	19	1	144
2026-05-24	19	2	166
2026-05-24	19	3	96
2026-05-24	20	1	158
2026-05-24	20	2	78
2026-05-24	20	3	102
2026-05-24	21	1	192
2026-05-24	21	2	240
2026-05-24	21	3	192
2026-05-24	22	1	73
2026-05-24	22	2	54
2026-05-24	22	3	109
2026-05-24	23	1	48
2026-05-24	23	2	132
2026-05-24	23	3	0
2026-05-24	24	1	228
2026-05-24	24	2	250
2026-05-24	24	3	303
2026-05-24	25	1	18
2026-05-24	25	2	78
2026-05-24	25	3	0
2026-05-24	26	1	123
2026-05-24	26	2	0
2026-05-24	26	3	362
2026-05-24	27	1	24
2026-05-24	27	2	53
2026-05-24	27	3	382
2026-05-24	28	1	136
2026-05-24	28	2	0
2026-05-24	28	3	67
2026-05-24	29	1	126
2026-05-24	29	2	5
2026-05-24	29	3	271
2026-05-24	30	1	567
2026-05-24	30	2	0
2026-05-24	30	3	801
2026-05-24	31	1	11
2026-05-24	31	2	840
2026-05-24	31	3	336
2026-05-24	32	1	47
2026-05-24	32	2	42
2026-05-24	32	3	30
2026-05-24	33	1	60
2026-05-24	33	2	90
2026-05-24	33	3	66
2026-05-24	34	1	12
2026-05-24	34	2	100
2026-05-24	34	3	96
2026-05-24	35	1	36
2026-05-24	35	2	60
2026-05-24	35	3	129
2026-05-24	36	1	226
2026-05-24	36	2	168
2026-05-24	36	3	201
2026-05-24	37	1	531
2026-05-24	37	2	565
2026-05-24	37	3	528
2026-05-24	38	1	252
2026-05-24	38	2	276
2026-05-24	38	3	114
2026-05-24	39	1	86
2026-05-24	39	2	154
2026-05-24	39	3	86
2026-05-24	40	1	65
2026-05-24	40	2	78
2026-05-24	40	3	60
2026-05-31	1	1	6
2026-05-31	1	2	42
2026-05-31	1	3	54
2026-05-31	2	1	156
2026-05-31	2	2	22
2026-05-31	2	3	144
2026-05-31	3	1	144
2026-05-31	3	2	84
2026-05-31	3	3	12
2026-05-31	4	1	0
2026-05-31	4	2	187
2026-05-31	4	3	96
2026-05-31	5	1	0
2026-05-31	5	2	192
2026-05-31	5	3	336
2026-05-31	6	1	57
2026-05-31	6	2	359
2026-05-31	6	3	0
2026-05-31	7	1	41
2026-05-31	7	2	39
2026-05-31	7	3	42
2026-05-31	8	1	54
2026-05-31	8	2	14
2026-05-31	8	3	48
2026-05-31	9	1	168
2026-05-31	9	2	0
2026-05-31	9	3	48
2026-05-31	10	1	0
2026-05-31	10	2	144
2026-05-31	10	3	0
2026-05-31	11	1	48
2026-05-31	11	2	52
2026-05-31	11	3	35
2026-05-31	12	1	602
2026-05-31	12	2	624
2026-05-31	12	3	397
2026-05-31	13	1	110
2026-05-31	13	2	182
2026-05-31	13	3	72
2026-05-31	14	1	132
2026-05-31	14	2	72
2026-05-31	14	3	72
2026-05-31	15	1	240
2026-05-31	15	2	230
2026-05-31	15	3	88
2026-05-31	16	1	402
2026-05-31	16	2	306
2026-05-31	16	3	183
2026-05-31	17	1	59
2026-05-31	17	2	95
2026-05-31	17	3	52
2026-05-31	18	1	211
2026-05-31	18	2	408
2026-05-31	18	3	384
2026-05-31	19	1	144
2026-05-31	19	2	166
2026-05-31	19	3	288
2026-05-31	20	1	146
2026-05-31	20	2	144
2026-05-31	20	3	102
2026-05-31	21	1	192
2026-05-31	21	2	240
2026-05-31	21	3	192
2026-05-31	22	1	67
2026-05-31	22	2	54
2026-05-31	22	3	91
2026-05-31	23	1	48
2026-05-31	23	2	132
2026-05-31	23	3	132
2026-05-31	24	1	180
2026-05-31	24	2	154
2026-05-31	24	3	183
2026-05-31	25	1	0
2026-05-31	25	2	54
2026-05-31	25	3	66
2026-05-31	26	1	123
2026-05-31	26	2	0
2026-05-31	26	3	362
2026-05-31	27	1	0
2026-05-31	27	2	53
2026-05-31	27	3	382
2026-05-31	28	1	136
2026-05-31	28	2	0
2026-05-31	28	3	67
2026-05-31	29	1	120
2026-05-31	29	2	0
2026-05-31	29	3	259
2026-05-31	30	1	519
2026-05-31	30	2	0
2026-05-31	30	3	801
2026-05-31	31	1	0
2026-05-31	31	2	720
2026-05-31	31	3	336
2026-05-31	32	1	29
2026-05-31	32	2	42
2026-05-31	32	3	30
2026-05-31	33	1	126
2026-05-31	33	2	72
2026-05-31	33	3	126
2026-05-31	34	1	12
2026-05-31	34	2	100
2026-05-31	34	3	60
2026-05-31	35	1	36
2026-05-31	35	2	132
2026-05-31	35	3	105
2026-05-31	36	1	226
2026-05-31	36	2	168
2026-05-31	36	3	129
2026-05-31	37	1	339
2026-05-31	37	2	541
2026-05-31	37	3	336
2026-05-31	38	1	216
2026-05-31	38	2	204
2026-05-31	38	3	306
2026-05-31	39	1	68
2026-05-31	39	2	136
2026-05-31	39	3	68
2026-05-31	40	1	47
2026-05-31	40	2	78
2026-05-31	40	3	54
2026-06-07	1	1	30
2026-06-07	1	2	60
2026-06-07	1	3	24
2026-06-07	2	1	96
2026-06-07	2	2	84
2026-06-07	2	3	84
2026-06-07	3	1	132
2026-06-07	3	2	48
2026-06-07	3	3	0
2026-06-07	4	1	108
2026-06-07	4	2	79
2026-06-07	4	3	228
2026-06-07	5	1	72
2026-06-07	5	2	336
2026-06-07	5	3	120
2026-06-07	6	1	57
2026-06-07	6	2	263
2026-06-07	6	3	131
2026-06-07	7	1	23
2026-06-07	7	2	39
2026-06-07	7	3	30
2026-06-07	8	1	30
2026-06-07	8	2	0
2026-06-07	8	3	48
2026-06-07	9	1	120
2026-06-07	9	2	0
2026-06-07	9	3	360
2026-06-07	10	1	0
2026-06-07	10	2	144
2026-06-07	10	3	24
2026-06-07	11	1	18
2026-06-07	11	2	46
2026-06-07	11	3	35
2026-06-07	12	1	482
2026-06-07	12	2	552
2026-06-07	12	3	229
2026-06-07	13	1	74
2026-06-07	13	2	110
2026-06-07	13	3	24
2026-06-07	14	1	108
2026-06-07	14	2	24
2026-06-07	14	3	72
2026-06-07	15	1	240
2026-06-07	15	2	230
2026-06-07	15	3	196
2026-06-07	16	1	354
2026-06-07	16	2	306
2026-06-07	16	3	423
2026-06-07	17	1	47
2026-06-07	17	2	89
2026-06-07	17	3	40
2026-06-07	18	1	403
2026-06-07	18	2	360
2026-06-07	18	3	384
2026-06-07	19	1	288
2026-06-07	19	2	166
2026-06-07	19	3	216
2026-06-07	20	1	116
2026-06-07	20	2	138
2026-06-07	20	3	168
2026-06-07	21	1	168
2026-06-07	21	2	120
2026-06-07	21	3	120
2026-06-07	22	1	67
2026-06-07	22	2	108
2026-06-07	22	3	79
2026-06-07	23	1	48
2026-06-07	23	2	108
2026-06-07	23	3	132
2026-06-07	24	1	516
2026-06-07	24	2	466
2026-06-07	24	3	0
2026-06-07	25	1	60
2026-06-07	25	2	42
2026-06-07	25	3	48
2026-06-07	26	1	105
2026-06-07	26	2	0
2026-06-07	26	3	350
2026-06-07	27	1	0
2026-06-07	27	2	53
2026-06-07	27	3	358
2026-06-07	28	1	184
2026-06-07	28	2	48
2026-06-07	28	3	115
2026-06-07	29	1	108
2026-06-07	29	2	0
2026-06-07	29	3	259
2026-06-07	30	1	375
2026-06-07	30	2	0
2026-06-07	30	3	801
2026-06-07	31	1	552
2026-06-07	31	2	648
2026-06-07	31	3	576
2026-06-07	32	1	29
2026-06-07	32	2	36
2026-06-07	32	3	60
2026-06-07	33	1	126
2026-06-07	33	2	72
2026-06-07	33	3	84
2026-06-07	34	1	72
2026-06-07	34	2	100
2026-06-07	34	3	60
2026-06-07	35	1	108
2026-06-07	35	2	132
2026-06-07	35	3	69
2026-06-07	36	1	178
2026-06-07	36	2	168
2026-06-07	36	3	81
2026-06-07	37	1	171
2026-06-07	37	2	373
2026-06-07	37	3	768
2026-06-07	38	1	216
2026-06-07	38	2	180
2026-06-07	38	3	270
2026-06-07	39	1	152
2026-06-07	39	2	130
2026-06-07	39	3	152
2026-06-07	40	1	47
2026-06-07	40	2	78
2026-06-07	40	3	90
2026-06-14	1	1	0
2026-06-14	1	2	30
2026-06-14	1	3	42
2026-06-14	2	1	72
2026-06-14	2	2	0
2026-06-14	2	3	0
2026-06-14	3	1	0
2026-06-14	3	2	108
2026-06-14	3	3	24
2026-06-14	4	1	24
2026-06-14	4	2	156
2026-06-14	4	3	144
2026-06-14	5	1	238
2026-06-14	5	2	72
2026-06-14	5	3	24
2026-06-14	6	1	0
2026-06-14	6	2	191
2026-06-14	6	3	131
2026-06-14	7	1	23
2026-06-14	7	2	27
2026-06-14	7	3	30
2026-06-14	8	1	0
2026-06-14	8	2	0
2026-06-14	8	3	48
2026-06-14	9	1	0
2026-06-14	9	2	264
2026-06-14	9	3	288
2026-06-14	10	1	120
2026-06-14	10	2	144
2026-06-14	10	3	24
2026-06-14	11	1	0
2026-06-14	11	2	46
2026-06-14	11	3	65
2026-06-14	12	1	362
2026-06-14	12	2	288
2026-06-14	12	3	589
2026-06-14	13	1	146
2026-06-14	13	2	50
2026-06-14	13	3	96
2026-06-14	14	1	96
2026-06-14	14	2	72
2026-06-14	14	3	156
2026-06-14	15	1	240
2026-06-14	15	2	230
2026-06-14	15	3	100
2026-06-14	16	1	306
2026-06-14	16	2	282
2026-06-14	16	3	375
2026-06-14	17	1	95
2026-06-14	17	2	59
2026-06-14	17	3	28
2026-06-14	18	1	403
2026-06-14	18	2	360
2026-06-14	18	3	384
2026-06-14	19	1	216
2026-06-14	19	2	166
2026-06-14	19	3	216
2026-06-14	20	1	116
2026-06-14	20	2	120
2026-06-14	20	3	168
2026-06-14	21	1	168
2026-06-14	21	2	120
2026-06-14	21	3	0
2026-06-14	22	1	67
2026-06-14	22	2	108
2026-06-14	22	3	79
2026-06-14	23	1	168
2026-06-14	23	2	96
2026-06-14	23	3	132
2026-06-14	24	1	516
2026-06-14	24	2	442
2026-06-14	24	3	312
2026-06-14	25	1	12
2026-06-14	25	2	42
2026-06-14	25	3	48
2026-06-14	26	1	189
2026-06-14	26	2	78
2026-06-14	26	3	458
2026-06-14	27	1	0
2026-06-14	27	2	41
2026-06-14	27	3	358
2026-06-14	28	1	148
2026-06-14	28	2	12
2026-06-14	28	3	79
2026-06-14	29	1	102
2026-06-14	29	2	0
2026-06-14	29	3	259
2026-06-14	30	1	279
2026-06-14	30	2	0
2026-06-14	30	3	801
2026-06-14	31	1	864
2026-06-14	31	2	528
2026-06-14	31	3	336
2026-06-14	32	1	59
2026-06-14	32	2	12
2026-06-14	32	3	60
2026-06-14	33	1	114
2026-06-14	33	2	120
2026-06-14	33	3	60
2026-06-14	34	1	72
2026-06-14	34	2	88
2026-06-14	34	3	48
2026-06-14	35	1	108
2026-06-14	35	2	120
2026-06-14	35	3	69
2026-06-14	36	1	178
2026-06-14	36	2	168
2026-06-14	36	3	201
2026-06-14	37	1	675
2026-06-14	37	2	205
2026-06-14	37	3	696
2026-06-14	38	1	84
2026-06-14	38	2	120
2026-06-14	38	3	234
2026-06-14	39	1	86
2026-06-14	39	2	112
2026-06-14	39	3	140
2026-06-14	40	1	95
2026-06-14	40	2	72
2026-06-14	40	3	84
2026-06-21	1	1	54
2026-06-21	1	2	60
2026-06-21	1	3	66
2026-06-21	2	1	18
2026-06-21	2	2	0
2026-06-21	2	3	0
2026-06-21	3	1	0
2026-06-21	3	2	108
2026-06-21	3	3	96
2026-06-21	4	1	120
2026-06-21	4	2	84
2026-06-21	4	3	12
2026-06-21	5	1	94
2026-06-21	5	2	0
2026-06-21	5	3	216
2026-06-21	6	1	0
2026-06-21	6	2	95
2026-06-21	6	3	35
2026-06-21	7	1	23
2026-06-21	7	2	9
2026-06-21	7	3	24
2026-06-21	8	1	41
2026-06-21	8	2	0
2026-06-21	8	3	102
2026-06-21	9	1	0
2026-06-21	9	2	216
2026-06-21	9	3	240
2026-06-21	10	1	24
2026-06-21	10	2	144
2026-06-21	10	3	0
2026-06-21	11	1	36
2026-06-21	11	2	34
2026-06-21	11	3	65
2026-06-21	12	1	314
2026-06-21	12	2	720
2026-06-21	12	3	397
2026-06-21	13	1	146
2026-06-21	13	2	50
2026-06-21	13	3	0
2026-06-21	14	1	96
2026-06-21	14	2	36
2026-06-21	14	3	156
2026-06-21	15	1	180
2026-06-21	15	2	194
2026-06-21	15	3	100
2026-06-21	16	1	277
2026-06-21	16	2	546
2026-06-21	16	3	351
2026-06-21	17	1	95
2026-06-21	17	2	59
2026-06-21	17	3	88
2026-06-21	18	1	403
2026-06-21	18	2	360
2026-06-21	18	3	384
2026-06-21	19	1	216
2026-06-21	19	2	166
2026-06-21	19	3	144
2026-06-21	20	1	110
2026-06-21	20	2	120
2026-06-21	20	3	168
2026-06-21	21	1	72
2026-06-21	21	2	120
2026-06-21	21	3	0
2026-06-21	22	1	67
2026-06-21	22	2	90
2026-06-21	22	3	61
2026-06-21	23	1	132
2026-06-21	23	2	24
2026-06-21	23	3	132
2026-06-21	24	1	444
2026-06-21	24	2	442
2026-06-21	24	3	192
2026-06-21	25	1	12
2026-06-21	25	2	42
2026-06-21	25	3	36
2026-06-21	26	1	177
2026-06-21	26	2	78
2026-06-21	26	3	446
2026-06-21	27	1	0
2026-06-21	27	2	17
2026-06-21	27	3	358
2026-06-21	28	1	148
2026-06-21	28	2	12
2026-06-21	28	3	79
2026-06-21	29	1	96
2026-06-21	29	2	0
2026-06-21	29	3	259
2026-06-21	30	1	255
2026-06-21	30	2	0
2026-06-21	30	3	801
2026-06-21	31	1	696
2026-06-21	31	2	504
2026-06-21	31	3	264
2026-06-21	32	1	35
2026-06-21	32	2	42
2026-06-21	32	3	48
2026-06-21	33	1	114
2026-06-21	33	2	114
2026-06-21	33	3	30
2026-06-21	34	1	72
2026-06-21	34	2	88
2026-06-21	34	3	12
2026-06-21	35	1	96
2026-06-21	35	2	108
2026-06-21	35	3	45
2026-06-21	36	1	106
2026-06-21	36	2	168
2026-06-21	36	3	201
2026-06-21	37	1	627
2026-06-21	37	2	613
2026-06-21	37	3	552
2026-06-21	38	1	48
2026-06-21	38	2	72
2026-06-21	38	3	186
2026-06-21	39	1	74
2026-06-21	39	2	70
2026-06-21	39	3	128
2026-06-21	40	1	95
2026-06-21	40	2	72
2026-06-21	40	3	84
2026-06-28	1	1	30
2026-06-28	1	2	36
2026-06-28	1	3	54
2026-06-28	2	1	0
2026-06-28	2	2	90
2026-06-28	2	3	78
2026-06-28	3	1	96
2026-06-28	3	2	60
2026-06-28	3	3	12
2026-06-28	4	1	60
2026-06-28	4	2	156
2026-06-28	4	3	168
2026-06-28	5	1	286
2026-06-28	5	2	240
2026-06-28	5	3	72
2026-06-28	6	1	288
2026-06-28	6	2	0
2026-06-28	6	3	0
2026-06-28	7	1	5
2026-06-28	7	2	3
2026-06-28	7	3	6
2026-06-28	8	1	41
2026-06-28	8	2	0
2026-06-28	8	3	66
2026-06-28	9	1	312
2026-06-28	9	2	72
2026-06-28	9	3	120
2026-06-28	10	1	24
2026-06-28	10	2	144
2026-06-28	10	3	87
2026-06-28	11	1	66
2026-06-28	11	2	34
2026-06-28	11	3	41
2026-06-28	12	1	650
2026-06-28	12	2	504
2026-06-28	12	3	325
2026-06-28	13	1	206
2026-06-28	13	2	14
2026-06-28	13	3	0
2026-06-28	14	1	96
2026-06-28	14	2	36
2026-06-28	14	3	132
2026-06-28	15	1	144
2026-06-28	15	2	194
2026-06-28	15	3	76
2026-06-28	16	1	277
2026-06-28	16	2	510
2026-06-28	16	3	267
2026-06-28	17	1	95
2026-06-28	17	2	59
2026-06-28	17	3	88
2026-06-28	18	1	355
2026-06-28	18	2	360
2026-06-28	18	3	360
2026-06-28	19	1	216
2026-06-28	19	2	166
2026-06-28	19	3	144
2026-06-28	20	1	110
2026-06-28	20	2	108
2026-06-28	20	3	156
2026-06-28	21	1	72
2026-06-28	21	2	120
2026-06-28	21	3	192
2026-06-28	22	1	67
2026-06-28	22	2	78
2026-06-28	22	3	43
2026-06-28	23	1	132
2026-06-28	23	2	0
2026-06-28	23	3	84
2026-06-28	24	1	324
2026-06-28	24	2	370
2026-06-28	24	3	120
2026-06-28	25	1	0
2026-06-28	25	2	84
2026-06-28	25	3	24
2026-06-28	26	1	141
2026-06-28	26	2	60
2026-06-28	26	3	428
2026-06-28	27	1	0
2026-06-28	27	2	0
2026-06-28	27	3	358
2026-06-28	28	1	112
2026-06-28	28	2	12
2026-06-28	28	3	55
2026-06-28	29	1	96
2026-06-28	29	2	0
2026-06-28	29	3	259
2026-06-28	30	1	519
2026-06-28	30	2	0
2026-06-28	30	3	801
2026-06-28	31	1	552
2026-06-28	31	2	264
2026-06-28	31	3	144
2026-06-28	32	1	23
2026-06-28	32	2	42
2026-06-28	32	3	36
2026-06-28	33	1	102
2026-06-28	33	2	78
2026-06-28	33	3	0
2026-06-28	34	1	12
2026-06-28	34	2	64
2026-06-28	34	3	60
2026-06-28	35	1	60
2026-06-28	35	2	96
2026-06-28	35	3	129
2026-06-28	36	1	106
2026-06-28	36	2	168
2026-06-28	36	3	201
2026-06-28	37	1	627
2026-06-28	37	2	397
2026-06-28	37	3	552
2026-06-28	38	1	228
2026-06-28	38	2	240
2026-06-28	38	3	186
2026-06-28	39	1	140
2026-06-28	39	2	46
2026-06-28	39	3	92
2026-06-28	40	1	89
2026-06-28	40	2	72
2026-06-28	40	3	84
2026-07-05	1	1	42
2026-07-05	1	2	24
2026-07-05	1	3	0
2026-07-05	2	1	54
2026-07-05	2	2	18
2026-07-05	2	3	0
2026-07-05	3	1	36
2026-07-05	3	2	0
2026-07-05	3	3	12
2026-07-05	4	1	72
2026-07-05	4	2	156
2026-07-05	4	3	0
2026-07-05	5	1	0
2026-07-05	5	2	360
2026-07-05	5	3	144
2026-07-05	6	1	72
2026-07-05	6	2	288
2026-07-05	6	3	408
2026-07-05	7	1	24
2026-07-05	7	2	3
2026-07-05	7	3	19
2026-07-05	8	1	41
2026-07-05	8	2	0
2026-07-05	8	3	30
2026-07-05	9	1	216
2026-07-05	9	2	0
2026-07-05	9	3	0
2026-07-05	10	1	0
2026-07-05	10	2	144
2026-07-05	10	3	0
2026-07-05	11	1	54
2026-07-05	11	2	0
2026-07-05	11	3	41
2026-07-05	12	1	458
2026-07-05	12	2	72
2026-07-05	12	3	637
2026-07-05	13	1	122
2026-07-05	13	2	110
2026-07-05	13	3	120
2026-07-05	14	1	60
2026-07-05	14	2	84
2026-07-05	14	3	108
2026-07-05	15	1	108
2026-07-05	15	2	122
2026-07-05	15	3	160
2026-07-05	16	1	505
2026-07-05	16	2	402
2026-07-05	16	3	231
2026-07-05	17	1	95
2026-07-05	17	2	53
2026-07-05	17	3	88
2026-07-05	18	1	355
2026-07-05	18	2	504
2026-07-05	18	3	360
2026-07-05	19	1	168
2026-07-05	19	2	142
2026-07-05	19	3	288
2026-07-05	20	1	86
2026-07-05	20	2	96
2026-07-05	20	3	138
2026-07-05	21	1	72
2026-07-05	21	2	240
2026-07-05	21	3	144
2026-07-05	22	1	61
2026-07-05	22	2	78
2026-07-05	22	3	19
2026-07-05	23	1	132
2026-07-05	23	2	120
2026-07-05	23	3	84
2026-07-05	24	1	324
2026-07-05	24	2	346
2026-07-05	24	3	240
2026-07-05	25	1	0
2026-07-05	25	2	78
2026-07-05	25	3	12
2026-07-05	26	1	123
2026-07-05	26	2	12
2026-07-05	26	3	428
2026-07-05	27	1	0
2026-07-05	27	2	0
2026-07-05	27	3	358
2026-07-05	28	1	112
2026-07-05	28	2	48
2026-07-05	28	3	103
2026-07-05	29	1	168
2026-07-05	29	2	72
2026-07-05	29	3	331
2026-07-05	30	1	519
2026-07-05	30	2	264
2026-07-05	30	3	1065
2026-07-05	31	1	216
2026-07-05	31	2	696
2026-07-05	31	3	552
2026-07-05	32	1	23
2026-07-05	32	2	24
2026-07-05	32	3	12
2026-07-05	33	1	78
2026-07-05	33	2	60
2026-07-05	33	3	60
2026-07-05	34	1	72
2026-07-05	34	2	52
2026-07-05	34	3	24
2026-07-05	35	1	132
2026-07-05	35	2	36
2026-07-05	35	3	93
2026-07-05	36	1	250
2026-07-05	36	2	144
2026-07-05	36	3	129
2026-07-05	37	1	507
2026-07-05	37	2	133
2026-07-05	37	3	408
2026-07-05	38	1	168
2026-07-05	38	2	192
2026-07-05	38	3	162
2026-07-05	39	1	116
2026-07-05	39	2	112
2026-07-05	39	3	56
2026-07-05	40	1	71
2026-07-05	40	2	72
2026-07-05	40	3	54
2026-07-12	1	1	66
2026-07-12	1	2	60
2026-07-12	1	3	31
2026-07-12	2	1	0
2026-07-12	2	2	84
2026-07-12	2	3	96
2026-07-12	3	1	108
2026-07-12	3	2	96
2026-07-12	3	3	0
2026-07-12	4	1	24
2026-07-12	4	2	12
2026-07-12	4	3	180
2026-07-12	5	1	0
2026-07-12	5	2	336
2026-07-12	5	3	0
2026-07-12	6	1	0
2026-07-12	6	2	288
2026-07-12	6	3	360
2026-07-12	7	1	12
2026-07-12	7	2	0
2026-07-12	7	3	13
2026-07-12	8	1	23
2026-07-12	8	2	0
2026-07-12	8	3	0
2026-07-12	9	1	192
2026-07-12	9	2	0
2026-07-12	9	3	0
2026-07-12	10	1	0
2026-07-12	10	2	144
2026-07-12	10	3	0
2026-07-12	11	1	42
2026-07-12	11	2	18
2026-07-12	11	3	35
2026-07-12	12	1	242
2026-07-12	12	2	0
2026-07-12	12	3	373
2026-07-12	13	1	122
2026-07-12	13	2	158
2026-07-12	13	3	60
2026-07-12	14	1	24
2026-07-12	14	2	84
2026-07-12	14	3	72
2026-07-12	15	1	180
2026-07-12	15	2	62
2026-07-12	15	3	76
2026-07-12	16	1	505
2026-07-12	16	2	378
2026-07-12	16	3	459
2026-07-12	17	1	95
2026-07-12	17	2	35
2026-07-12	17	3	70
2026-07-12	18	1	297
2026-07-12	18	2	480
2026-07-12	18	3	360
2026-07-12	19	1	168
2026-07-12	19	2	142
2026-07-12	19	3	240
2026-07-12	20	1	140
2026-07-12	20	2	96
2026-07-12	20	3	126
2026-07-12	21	1	288
2026-07-12	21	2	216
2026-07-12	21	3	96
2026-07-12	22	1	61
2026-07-12	22	2	78
2026-07-12	22	3	61
2026-07-12	23	1	96
2026-07-12	23	2	120
2026-07-12	23	3	24
2026-07-12	24	1	252
2026-07-12	24	2	346
2026-07-12	24	3	192
2026-07-12	25	1	60
2026-07-12	25	2	54
2026-07-12	25	3	90
2026-07-12	26	1	117
2026-07-12	26	2	12
2026-07-12	26	3	410
2026-07-12	27	1	108
2026-07-12	27	2	132
2026-07-12	27	3	490
2026-07-12	28	1	148
2026-07-12	28	2	48
2026-07-12	28	3	103
2026-07-12	29	1	156
2026-07-12	29	2	42
2026-07-12	29	3	331
2026-07-12	30	1	423
2026-07-12	30	2	264
2026-07-12	30	3	1017
2026-07-12	31	1	48
2026-07-12	31	2	528
2026-07-12	31	3	504
2026-07-12	32	1	59
2026-07-12	32	2	24
2026-07-12	32	3	60
2026-07-12	33	1	42
2026-07-12	33	2	24
2026-07-12	33	3	30
2026-07-12	34	1	72
2026-07-12	34	2	28
2026-07-12	34	3	24
2026-07-12	35	1	132
2026-07-12	35	2	48
2026-07-12	35	3	69
2026-07-12	36	1	250
2026-07-12	36	2	144
2026-07-12	36	3	57
2026-07-12	37	1	459
2026-07-12	37	2	661
2026-07-12	37	3	336
2026-07-12	38	1	168
2026-07-12	38	2	180
2026-07-12	38	3	114
2026-07-12	39	1	116
2026-07-12	39	2	112
2026-07-12	39	3	44
2026-07-12	40	1	65
2026-07-12	40	2	54
2026-07-12	40	3	54
2026-07-19	1	1	60
2026-07-19	1	2	12
2026-07-19	1	3	7
2026-07-19	2	1	97
2026-07-19	2	2	48
2026-07-19	2	3	48
2026-07-19	3	1	108
2026-07-19	3	2	156
2026-07-19	3	3	0
2026-07-19	4	1	132
2026-07-19	4	2	132
2026-07-19	4	3	108
2026-07-19	5	1	432
2026-07-19	5	2	288
2026-07-19	5	3	264
2026-07-19	6	1	0
2026-07-19	6	2	240
2026-07-19	6	3	336
2026-07-19	7	1	12
2026-07-19	7	2	25
2026-07-19	7	3	13
2026-07-19	8	1	17
2026-07-19	8	2	0
2026-07-19	8	3	0
2026-07-19	9	1	48
2026-07-19	9	2	336
2026-07-19	9	3	312
2026-07-19	10	1	0
2026-07-19	10	2	144
2026-07-19	10	3	0
2026-07-19	11	1	42
2026-07-19	11	2	18
2026-07-19	11	3	23
2026-07-19	12	1	602
2026-07-19	12	2	552
2026-07-19	12	3	325
2026-07-19	13	1	62
2026-07-19	13	2	158
2026-07-19	13	3	168
2026-07-19	14	1	24
2026-07-19	14	2	108
2026-07-19	14	3	48
2026-07-19	15	1	180
2026-07-19	15	2	194
2026-07-19	15	3	64
2026-07-19	16	1	397
2026-07-19	16	2	378
2026-07-19	16	3	411
2026-07-19	17	1	95
2026-07-19	17	2	29
2026-07-19	17	3	70
2026-07-19	18	1	297
2026-07-19	18	2	360
2026-07-19	18	3	360
2026-07-19	19	1	168
2026-07-19	19	2	286
2026-07-19	19	3	240
2026-07-19	20	1	140
2026-07-19	20	2	96
2026-07-19	20	3	126
2026-07-19	21	1	192
2026-07-19	21	2	216
2026-07-19	21	3	48
2026-07-19	22	1	31
2026-07-19	22	2	48
2026-07-19	22	3	49
2026-07-19	23	1	84
2026-07-19	23	2	96
2026-07-19	23	3	0
2026-07-19	24	1	204
2026-07-19	24	2	346
2026-07-19	24	3	504
2026-07-19	25	1	30
2026-07-19	25	2	48
2026-07-19	25	3	78
2026-07-19	26	1	117
2026-07-19	26	2	0
2026-07-19	26	3	410
2026-07-19	27	1	108
2026-07-19	27	2	108
2026-07-19	27	3	490
2026-07-19	28	1	136
2026-07-19	28	2	48
2026-07-19	28	3	103
2026-07-19	29	1	138
2026-07-19	29	2	42
2026-07-19	29	3	331
2026-07-19	30	1	423
2026-07-19	30	2	168
2026-07-19	30	3	1017
2026-07-19	31	1	336
2026-07-19	31	2	408
2026-07-19	31	3	960
2026-07-19	32	1	53
2026-07-19	32	2	60
2026-07-19	32	3	36
2026-07-19	33	1	30
2026-07-19	33	2	96
2026-07-19	33	3	102
2026-07-19	34	1	72
2026-07-19	34	2	76
2026-07-19	34	3	60
2026-07-19	35	1	108
2026-07-19	35	2	48
2026-07-19	35	3	69
2026-07-19	36	1	250
2026-07-19	36	2	240
2026-07-19	36	3	129
2026-07-19	37	1	459
2026-07-19	37	2	517
2026-07-19	37	3	288
2026-07-19	38	1	360
2026-07-19	38	2	156
2026-07-19	38	3	270
2026-07-19	39	1	104
2026-07-19	39	2	106
2026-07-19	39	3	134
2026-07-19	40	1	53
2026-07-19	40	2	54
2026-07-19	40	3	36
2026-07-26	1	1	12
2026-07-26	1	2	54
2026-07-26	1	3	61
2026-07-26	2	1	19
2026-07-26	2	2	12
2026-07-26	2	3	42
2026-07-26	3	1	0
2026-07-26	3	2	12
2026-07-26	3	3	132
2026-07-26	4	1	48
2026-07-26	4	2	60
2026-07-26	4	3	60
2026-07-26	5	1	168
2026-07-26	5	2	24
2026-07-26	5	3	312
2026-07-26	6	1	0
2026-07-26	6	2	216
2026-07-26	6	3	240
2026-07-26	7	1	12
2026-07-26	7	2	0
2026-07-26	7	3	7
2026-07-26	8	1	53
2026-07-26	8	2	0
2026-07-26	8	3	0
2026-07-26	9	1	48
2026-07-26	9	2	288
2026-07-26	9	3	264
2026-07-26	10	1	168
2026-07-26	10	2	120
2026-07-26	10	3	120
2026-07-26	11	1	30
2026-07-26	11	2	48
2026-07-26	11	3	59
2026-07-26	12	1	434
2026-07-26	12	2	528
2026-07-26	12	3	685
2026-07-26	13	1	38
2026-07-26	13	2	158
2026-07-26	13	3	168
2026-07-26	14	1	120
2026-07-26	14	2	60
2026-07-26	14	3	24
2026-07-26	15	1	156
2026-07-26	15	2	122
2026-07-26	15	3	148
2026-07-26	16	1	341
2026-07-26	16	2	330
2026-07-26	16	3	351
2026-07-26	17	1	89
2026-07-26	17	2	89
2026-07-26	17	3	70
2026-07-26	18	1	513
2026-07-26	18	2	216
2026-07-26	18	3	432
2026-07-26	19	1	144
2026-07-26	19	2	286
2026-07-26	19	3	216
2026-07-26	20	1	80
2026-07-26	20	2	78
2026-07-26	20	3	114
2026-07-26	21	1	144
2026-07-26	21	2	216
2026-07-26	21	3	48
2026-07-26	22	1	0
2026-07-26	22	2	6
2026-07-26	22	3	49
2026-07-26	23	1	72
2026-07-26	23	2	96
2026-07-26	23	3	0
2026-07-26	24	1	444
2026-07-26	24	2	226
2026-07-26	24	3	384
2026-07-26	25	1	24
2026-07-26	25	2	48
2026-07-26	25	3	78
2026-07-26	26	1	111
2026-07-26	26	2	0
2026-07-26	26	3	392
2026-07-26	27	1	108
2026-07-26	27	2	72
2026-07-26	27	3	490
2026-07-26	28	1	124
2026-07-26	28	2	48
2026-07-26	28	3	103
2026-07-26	29	1	108
2026-07-26	29	2	36
2026-07-26	29	3	331
2026-07-26	30	1	423
2026-07-26	30	2	168
2026-07-26	30	3	1017
2026-07-26	31	1	192
2026-07-26	31	2	744
2026-07-26	31	3	888
2026-07-26	32	1	53
2026-07-26	32	2	54
2026-07-26	32	3	18
2026-07-26	33	1	102
2026-07-26	33	2	36
2026-07-26	33	3	78
2026-07-26	34	1	72
2026-07-26	34	2	76
2026-07-26	34	3	36
2026-07-26	35	1	48
2026-07-26	35	2	88
2026-07-26	35	3	45
2026-07-26	36	1	250
2026-07-26	36	2	216
2026-07-26	36	3	129
2026-07-26	37	1	387
2026-07-26	37	2	205
2026-07-26	37	3	744
2026-07-26	38	1	336
2026-07-26	38	2	300
2026-07-26	38	3	270
2026-07-26	39	1	74
2026-07-26	39	2	82
2026-07-26	39	3	116
2026-07-26	40	1	53
2026-07-26	40	2	54
2026-07-26	40	3	78
\.
COPY demand_forecasts (product_id, dc_id, forecast_month, forecast_units) FROM stdin;
1	1	2025-11-01	45
2	1	2025-11-01	76
3	1	2025-11-01	86
4	1	2025-11-01	172
5	1	2025-11-01	228
6	1	2025-11-01	300
7	1	2025-11-01	26
8	1	2025-11-01	38
9	1	2025-11-01	269
10	1	2025-11-01	104
11	1	2025-11-01	29
12	1	2025-11-01	389
13	1	2025-11-01	91
14	1	2025-11-01	50
15	1	2025-11-01	109
16	1	2025-11-01	272
17	1	2025-11-01	53
18	1	2025-11-01	191
19	1	2025-11-01	132
20	1	2025-11-01	61
21	1	2025-11-01	171
22	1	2025-11-01	51
23	1	2025-11-01	123
24	1	2025-11-01	298
25	1	2025-11-01	72
26	1	2025-11-01	106
27	1	2025-11-01	126
28	1	2025-11-01	42
29	1	2025-11-01	60
30	1	2025-11-01	209
31	1	2025-11-01	537
32	1	2025-11-01	21
33	1	2025-11-01	65
34	1	2025-11-01	36
35	1	2025-11-01	53
36	1	2025-11-01	119
37	1	2025-11-01	640
38	1	2025-11-01	165
39	1	2025-11-01	85
40	1	2025-11-01	43
1	2	2025-11-01	44
2	2	2025-11-01	82
3	2	2025-11-01	78
4	2	2025-11-01	180
5	2	2025-11-01	240
6	2	2025-11-01	309
7	2	2025-11-01	24
8	2	2025-11-01	53
9	2	2025-11-01	274
10	2	2025-11-01	76
11	2	2025-11-01	27
12	2	2025-11-01	457
13	2	2025-11-01	83
14	2	2025-11-01	51
15	2	2025-11-01	126
16	2	2025-11-01	279
17	2	2025-11-01	48
18	2	2025-11-01	212
19	2	2025-11-01	131
20	2	2025-11-01	67
21	2	2025-11-01	160
22	2	2025-11-01	52
23	2	2025-11-01	108
24	2	2025-11-01	254
25	2	2025-11-01	71
26	2	2025-11-01	113
27	2	2025-11-01	141
28	2	2025-11-01	46
29	2	2025-11-01	70
30	2	2025-11-01	261
31	2	2025-11-01	575
32	2	2025-11-01	26
33	2	2025-11-01	72
34	2	2025-11-01	34
35	2	2025-11-01	59
36	2	2025-11-01	103
37	2	2025-11-01	557
38	2	2025-11-01	178
39	2	2025-11-01	82
40	2	2025-11-01	36
1	3	2025-11-01	42
2	3	2025-11-01	76
3	3	2025-11-01	90
4	3	2025-11-01	153
5	3	2025-11-01	238
6	3	2025-11-01	318
7	3	2025-11-01	24
8	3	2025-11-01	47
9	3	2025-11-01	282
10	3	2025-11-01	83
11	3	2025-11-01	32
12	3	2025-11-01	448
13	3	2025-11-01	99
14	3	2025-11-01	52
15	3	2025-11-01	113
16	3	2025-11-01	269
17	3	2025-11-01	48
18	3	2025-11-01	210
19	3	2025-11-01	126
20	3	2025-11-01	59
21	3	2025-11-01	171
22	3	2025-11-01	55
23	3	2025-11-01	105
24	3	2025-11-01	284
25	3	2025-11-01	64
26	3	2025-11-01	114
27	3	2025-11-01	133
28	3	2025-11-01	47
29	3	2025-11-01	76
30	3	2025-11-01	258
31	3	2025-11-01	530
32	3	2025-11-01	22
33	3	2025-11-01	74
34	3	2025-11-01	32
35	3	2025-11-01	50
36	3	2025-11-01	110
37	3	2025-11-01	493
38	3	2025-11-01	159
39	3	2025-11-01	80
40	3	2025-11-01	35
1	1	2025-12-01	52
2	1	2025-12-01	83
3	1	2025-12-01	87
4	1	2025-12-01	193
5	1	2025-12-01	284
6	1	2025-12-01	318
7	1	2025-12-01	32
8	1	2025-12-01	61
9	1	2025-12-01	346
10	1	2025-12-01	98
11	1	2025-12-01	35
12	1	2025-12-01	472
13	1	2025-12-01	100
14	1	2025-12-01	60
15	1	2025-12-01	130
16	1	2025-12-01	341
17	1	2025-12-01	54
18	1	2025-12-01	220
19	1	2025-12-01	117
20	1	2025-12-01	76
21	1	2025-12-01	202
22	1	2025-12-01	54
23	1	2025-12-01	121
24	1	2025-12-01	363
25	1	2025-12-01	79
26	1	2025-12-01	157
27	1	2025-12-01	164
28	1	2025-12-01	58
29	1	2025-12-01	91
30	1	2025-12-01	364
31	1	2025-12-01	472
32	1	2025-12-01	26
33	1	2025-12-01	77
34	1	2025-12-01	44
35	1	2025-12-01	57
36	1	2025-12-01	117
37	1	2025-12-01	618
38	1	2025-12-01	239
39	1	2025-12-01	91
40	1	2025-12-01	44
1	2	2025-12-01	51
2	2	2025-12-01	82
3	2	2025-12-01	81
4	2	2025-12-01	152
5	2	2025-12-01	273
6	2	2025-12-01	368
7	2	2025-12-01	26
8	2	2025-12-01	55
9	2	2025-12-01	351
10	2	2025-12-01	90
11	2	2025-12-01	33
12	2	2025-12-01	492
13	2	2025-12-01	92
14	2	2025-12-01	59
15	2	2025-12-01	120
16	2	2025-12-01	360
17	2	2025-12-01	65
18	2	2025-12-01	222
19	2	2025-12-01	123
20	2	2025-12-01	77
21	2	2025-12-01	193
22	2	2025-12-01	63
23	2	2025-12-01	133
24	2	2025-12-01	283
25	2	2025-12-01	78
26	2	2025-12-01	140
27	2	2025-12-01	159
28	2	2025-12-01	62
29	2	2025-12-01	92
30	2	2025-12-01	371
31	2	2025-12-01	610
32	2	2025-12-01	26
33	2	2025-12-01	93
34	2	2025-12-01	40
35	2	2025-12-01	66
36	2	2025-12-01	121
37	2	2025-12-01	593
38	2	2025-12-01	207
39	2	2025-12-01	102
40	2	2025-12-01	39
1	3	2025-12-01	47
2	3	2025-12-01	83
3	3	2025-12-01	95
4	3	2025-12-01	197
5	3	2025-12-01	251
6	3	2025-12-01	354
7	3	2025-12-01	25
8	3	2025-12-01	58
9	3	2025-12-01	323
10	3	2025-12-01	92
11	3	2025-12-01	37
12	3	2025-12-01	448
13	3	2025-12-01	115
14	3	2025-12-01	60
15	3	2025-12-01	134
16	3	2025-12-01	281
17	3	2025-12-01	50
18	3	2025-12-01	199
19	3	2025-12-01	115
20	3	2025-12-01	68
21	3	2025-12-01	175
22	3	2025-12-01	59
23	3	2025-12-01	111
24	3	2025-12-01	284
25	3	2025-12-01	75
26	3	2025-12-01	149
27	3	2025-12-01	163
28	3	2025-12-01	61
29	3	2025-12-01	88
30	3	2025-12-01	331
31	3	2025-12-01	618
32	3	2025-12-01	29
33	3	2025-12-01	85
34	3	2025-12-01	38
35	3	2025-12-01	67
36	3	2025-12-01	124
37	3	2025-12-01	622
38	3	2025-12-01	192
39	3	2025-12-01	111
40	3	2025-12-01	46
1	1	2026-01-01	46
2	1	2026-01-01	92
3	1	2026-01-01	78
4	1	2026-01-01	175
5	1	2026-01-01	275
6	1	2026-01-01	374
7	1	2026-01-01	27
8	1	2026-01-01	60
9	1	2026-01-01	343
10	1	2026-01-01	83
11	1	2026-01-01	37
12	1	2026-01-01	443
13	1	2026-01-01	98
14	1	2026-01-01	55
15	1	2026-01-01	150
16	1	2026-01-01	323
17	1	2026-01-01	60
18	1	2026-01-01	196
19	1	2026-01-01	160
20	1	2026-01-01	83
21	1	2026-01-01	189
22	1	2026-01-01	55
23	1	2026-01-01	129
24	1	2026-01-01	285
25	1	2026-01-01	92
26	1	2026-01-01	92
27	1	2026-01-01	108
28	1	2026-01-01	42
29	1	2026-01-01	59
30	1	2026-01-01	200
31	1	2026-01-01	658
32	1	2026-01-01	27
33	1	2026-01-01	75
34	1	2026-01-01	40
35	1	2026-01-01	62
36	1	2026-01-01	105
37	1	2026-01-01	530
38	1	2026-01-01	205
39	1	2026-01-01	115
40	1	2026-01-01	44
1	2	2026-01-01	50
2	2	2026-01-01	98
3	2	2026-01-01	94
4	2	2026-01-01	168
5	2	2026-01-01	284
6	2	2026-01-01	358
7	2	2026-01-01	30
8	2	2026-01-01	53
9	2	2026-01-01	332
10	2	2026-01-01	91
11	2	2026-01-01	35
12	2	2026-01-01	467
13	2	2026-01-01	107
14	2	2026-01-01	55
15	2	2026-01-01	126
16	2	2026-01-01	322
17	2	2026-01-01	58
18	2	2026-01-01	215
19	2	2026-01-01	144
20	2	2026-01-01	75
21	2	2026-01-01	182
22	2	2026-01-01	61
23	2	2026-01-01	123
24	2	2026-01-01	296
25	2	2026-01-01	76
26	2	2026-01-01	102
27	2	2026-01-01	97
28	2	2026-01-01	41
29	2	2026-01-01	57
30	2	2026-01-01	218
31	2	2026-01-01	722
32	2	2026-01-01	33
33	2	2026-01-01	89
34	2	2026-01-01	39
35	2	2026-01-01	57
36	2	2026-01-01	111
37	2	2026-01-01	717
38	2	2026-01-01	198
39	2	2026-01-01	89
40	2	2026-01-01	42
1	3	2026-01-01	54
2	3	2026-01-01	83
3	3	2026-01-01	95
4	3	2026-01-01	172
5	3	2026-01-01	273
6	3	2026-01-01	343
7	3	2026-01-01	26
8	3	2026-01-01	55
9	3	2026-01-01	369
10	3	2026-01-01	124
11	3	2026-01-01	30
12	3	2026-01-01	583
13	3	2026-01-01	104
14	3	2026-01-01	60
15	3	2026-01-01	137
16	3	2026-01-01	333
17	3	2026-01-01	64
18	3	2026-01-01	221
19	3	2026-01-01	122
20	3	2026-01-01	77
21	3	2026-01-01	178
22	3	2026-01-01	56
23	3	2026-01-01	135
24	3	2026-01-01	267
25	3	2026-01-01	65
26	3	2026-01-01	96
27	3	2026-01-01	127
28	3	2026-01-01	49
29	3	2026-01-01	62
30	3	2026-01-01	203
31	3	2026-01-01	659
32	3	2026-01-01	26
33	3	2026-01-01	98
34	3	2026-01-01	42
35	3	2026-01-01	66
36	3	2026-01-01	113
37	3	2026-01-01	618
38	3	2026-01-01	229
39	3	2026-01-01	90
40	3	2026-01-01	39
1	1	2026-02-01	43
2	1	2026-02-01	86
3	1	2026-02-01	72
4	1	2026-02-01	145
5	1	2026-02-01	239
6	1	2026-02-01	345
7	1	2026-02-01	25
8	1	2026-02-01	53
9	1	2026-02-01	344
10	1	2026-02-01	86
11	1	2026-02-01	32
12	1	2026-02-01	497
13	1	2026-02-01	101
14	1	2026-02-01	53
15	1	2026-02-01	134
16	1	2026-02-01	318
17	1	2026-02-01	60
18	1	2026-02-01	214
19	1	2026-02-01	132
20	1	2026-02-01	74
21	1	2026-02-01	196
22	1	2026-02-01	50
23	1	2026-02-01	124
24	1	2026-02-01	257
25	1	2026-02-01	77
26	1	2026-02-01	91
27	1	2026-02-01	92
28	1	2026-02-01	36
29	1	2026-02-01	51
30	1	2026-02-01	171
31	1	2026-02-01	604
32	1	2026-02-01	23
33	1	2026-02-01	63
34	1	2026-02-01	40
35	1	2026-02-01	60
36	1	2026-02-01	100
37	1	2026-02-01	491
38	1	2026-02-01	189
39	1	2026-02-01	82
40	1	2026-02-01	36
1	2	2026-02-01	49
2	2	2026-02-01	80
3	2	2026-02-01	86
4	2	2026-02-01	158
5	2	2026-02-01	262
6	2	2026-02-01	294
7	2	2026-02-01	28
8	2	2026-02-01	53
9	2	2026-02-01	327
10	2	2026-02-01	93
11	2	2026-02-01	29
12	2	2026-02-01	475
13	2	2026-02-01	95
14	2	2026-02-01	56
15	2	2026-02-01	119
16	2	2026-02-01	261
17	2	2026-02-01	50
18	2	2026-02-01	182
19	2	2026-02-01	135
20	2	2026-02-01	65
21	2	2026-02-01	188
22	2	2026-02-01	56
23	2	2026-02-01	117
24	2	2026-02-01	293
25	2	2026-02-01	61
26	2	2026-02-01	86
27	2	2026-02-01	92
28	2	2026-02-01	36
29	2	2026-02-01	54
30	2	2026-02-01	191
31	2	2026-02-01	540
32	2	2026-02-01	23
33	2	2026-02-01	75
34	2	2026-02-01	37
35	2	2026-02-01	57
36	2	2026-02-01	109
37	2	2026-02-01	484
38	2	2026-02-01	208
39	2	2026-02-01	95
40	2	2026-02-01	42
1	3	2026-02-01	43
2	3	2026-02-01	78
3	3	2026-02-01	74
4	3	2026-02-01	150
5	3	2026-02-01	246
6	3	2026-02-01	349
7	3	2026-02-01	22
8	3	2026-02-01	51
9	3	2026-02-01	351
10	3	2026-02-01	91
11	3	2026-02-01	33
12	3	2026-02-01	450
13	3	2026-02-01	89
14	3	2026-02-01	57
15	3	2026-02-01	116
16	3	2026-02-01	297
17	3	2026-02-01	49
18	3	2026-02-01	218
19	3	2026-02-01	125
20	3	2026-02-01	71
21	3	2026-02-01	176
22	3	2026-02-01	50
23	3	2026-02-01	111
24	3	2026-02-01	258
25	3	2026-02-01	74
26	3	2026-02-01	81
27	3	2026-02-01	101
28	3	2026-02-01	32
29	3	2026-02-01	55
30	3	2026-02-01	176
31	3	2026-02-01	583
32	3	2026-02-01	26
33	3	2026-02-01	79
34	3	2026-02-01	37
35	3	2026-02-01	50
36	3	2026-02-01	108
37	3	2026-02-01	505
38	3	2026-02-01	197
39	3	2026-02-01	85
40	3	2026-02-01	37
1	1	2026-03-01	58
2	1	2026-03-01	103
3	1	2026-03-01	103
4	1	2026-03-01	209
5	1	2026-03-01	331
6	1	2026-03-01	414
7	1	2026-03-01	30
8	1	2026-03-01	66
9	1	2026-03-01	388
10	1	2026-03-01	118
11	1	2026-03-01	42
12	1	2026-03-01	560
13	1	2026-03-01	111
14	1	2026-03-01	71
15	1	2026-03-01	150
16	1	2026-03-01	299
17	1	2026-03-01	58
18	1	2026-03-01	194
19	1	2026-03-01	126
20	1	2026-03-01	60
21	1	2026-03-01	169
22	1	2026-03-01	56
23	1	2026-03-01	107
24	1	2026-03-01	280
25	1	2026-03-01	66
26	1	2026-03-01	75
27	1	2026-03-01	103
28	1	2026-03-01	35
29	1	2026-03-01	48
30	1	2026-03-01	161
31	1	2026-03-01	686
32	1	2026-03-01	28
33	1	2026-03-01	97
34	1	2026-03-01	42
35	1	2026-03-01	75
36	1	2026-03-01	127
37	1	2026-03-01	634
38	1	2026-03-01	197
39	1	2026-03-01	84
40	1	2026-03-01	42
1	2	2026-03-01	51
2	2	2026-03-01	97
3	2	2026-03-01	96
4	2	2026-03-01	209
5	2	2026-03-01	326
6	2	2026-03-01	371
7	2	2026-03-01	33
8	2	2026-03-01	62
9	2	2026-03-01	394
10	2	2026-03-01	125
11	2	2026-03-01	36
12	2	2026-03-01	544
13	2	2026-03-01	113
14	2	2026-03-01	64
15	2	2026-03-01	152
16	2	2026-03-01	335
17	2	2026-03-01	50
18	2	2026-03-01	203
19	2	2026-03-01	115
20	2	2026-03-01	69
21	2	2026-03-01	186
22	2	2026-03-01	49
23	2	2026-03-01	109
24	2	2026-03-01	304
25	2	2026-03-01	74
26	2	2026-03-01	81
27	2	2026-03-01	91
28	2	2026-03-01	33
29	2	2026-03-01	47
30	2	2026-03-01	174
31	2	2026-03-01	694
32	2	2026-03-01	31
33	2	2026-03-01	98
34	2	2026-03-01	40
35	2	2026-03-01	63
36	2	2026-03-01	94
37	2	2026-03-01	587
38	2	2026-03-01	171
39	2	2026-03-01	98
40	2	2026-03-01	38
1	3	2026-03-01	52
2	3	2026-03-01	101
3	3	2026-03-01	98
4	3	2026-03-01	217
5	3	2026-03-01	322
6	3	2026-03-01	439
7	3	2026-03-01	33
8	3	2026-03-01	67
9	3	2026-03-01	418
10	3	2026-03-01	134
11	3	2026-03-01	42
12	3	2026-03-01	652
13	3	2026-03-01	110
14	3	2026-03-01	71
15	3	2026-03-01	142
16	3	2026-03-01	277
17	3	2026-03-01	46
18	3	2026-03-01	207
19	3	2026-03-01	137
20	3	2026-03-01	72
21	3	2026-03-01	157
22	3	2026-03-01	55
23	3	2026-03-01	107
24	3	2026-03-01	267
25	3	2026-03-01	66
26	3	2026-03-01	76
27	3	2026-03-01	84
28	3	2026-03-01	40
29	3	2026-03-01	51
30	3	2026-03-01	173
31	3	2026-03-01	664
32	3	2026-03-01	36
33	3	2026-03-01	87
34	3	2026-03-01	44
35	3	2026-03-01	61
36	3	2026-03-01	96
37	3	2026-03-01	574
38	3	2026-03-01	181
39	3	2026-03-01	87
40	3	2026-03-01	40
1	1	2026-04-01	64
2	1	2026-04-01	98
3	1	2026-04-01	115
4	1	2026-04-01	193
5	1	2026-04-01	308
6	1	2026-04-01	472
7	1	2026-04-01	32
8	1	2026-04-01	60
9	1	2026-04-01	425
10	1	2026-04-01	115
11	1	2026-04-01	39
12	1	2026-04-01	528
13	1	2026-04-01	97
14	1	2026-04-01	78
15	1	2026-04-01	157
16	1	2026-04-01	272
17	1	2026-04-01	52
18	1	2026-04-01	213
19	1	2026-04-01	119
20	1	2026-04-01	65
21	1	2026-04-01	161
22	1	2026-04-01	50
23	1	2026-04-01	113
24	1	2026-04-01	281
25	1	2026-04-01	71
26	1	2026-04-01	76
27	1	2026-04-01	86
28	1	2026-04-01	34
29	1	2026-04-01	48
30	1	2026-04-01	176
31	1	2026-04-01	649
32	1	2026-04-01	30
33	1	2026-04-01	93
34	1	2026-04-01	46
35	1	2026-04-01	75
36	1	2026-04-01	92
37	1	2026-04-01	484
38	1	2026-04-01	186
39	1	2026-04-01	85
40	1	2026-04-01	35
1	2	2026-04-01	62
2	2	2026-04-01	103
3	2	2026-04-01	100
4	2	2026-04-01	226
5	2	2026-04-01	298
6	2	2026-04-01	449
7	2	2026-04-01	28
8	2	2026-04-01	70
9	2	2026-04-01	351
10	2	2026-04-01	108
11	2	2026-04-01	34
12	2	2026-04-01	589
13	2	2026-04-01	119
14	2	2026-04-01	68
15	2	2026-04-01	144
16	2	2026-04-01	308
17	2	2026-04-01	51
18	2	2026-04-01	178
19	2	2026-04-01	128
20	2	2026-04-01	75
21	2	2026-04-01	196
22	2	2026-04-01	50
23	2	2026-04-01	112
24	2	2026-04-01	293
25	2	2026-04-01	68
26	2	2026-04-01	79
27	2	2026-04-01	89
28	2	2026-04-01	34
29	2	2026-04-01	45
30	2	2026-04-01	151
31	2	2026-04-01	675
32	2	2026-04-01	29
33	2	2026-04-01	92
34	2	2026-04-01	48
35	2	2026-04-01	62
36	2	2026-04-01	90
37	2	2026-04-01	479
38	2	2026-04-01	181
39	2	2026-04-01	85
40	2	2026-04-01	38
1	3	2026-04-01	61
2	3	2026-04-01	105
3	3	2026-04-01	108
4	3	2026-04-01	204
5	3	2026-04-01	306
6	3	2026-04-01	371
7	3	2026-04-01	36
8	3	2026-04-01	61
9	3	2026-04-01	334
10	3	2026-04-01	129
11	3	2026-04-01	38
12	3	2026-04-01	563
13	3	2026-04-01	110
14	3	2026-04-01	68
15	3	2026-04-01	144
16	3	2026-04-01	287
17	3	2026-04-01	50
18	3	2026-04-01	189
19	3	2026-04-01	121
20	3	2026-04-01	80
21	3	2026-04-01	155
22	3	2026-04-01	52
23	3	2026-04-01	115
24	3	2026-04-01	256
25	3	2026-04-01	77
26	3	2026-04-01	84
27	3	2026-04-01	93
28	3	2026-04-01	35
29	3	2026-04-01	47
30	3	2026-04-01	181
31	3	2026-04-01	710
32	3	2026-04-01	30
33	3	2026-04-01	93
34	3	2026-04-01	50
35	3	2026-04-01	81
36	3	2026-04-01	114
37	3	2026-04-01	599
38	3	2026-04-01	194
39	3	2026-04-01	84
40	3	2026-04-01	38
1	1	2026-05-01	58
2	1	2026-05-01	92
3	1	2026-05-01	104
4	1	2026-05-01	217
5	1	2026-05-01	293
6	1	2026-05-01	425
7	1	2026-05-01	36
8	1	2026-05-01	64
9	1	2026-05-01	441
10	1	2026-05-01	108
11	1	2026-05-01	42
12	1	2026-05-01	499
13	1	2026-05-01	112
14	1	2026-05-01	79
15	1	2026-05-01	129
16	1	2026-05-01	241
17	1	2026-05-01	53
18	1	2026-05-01	206
19	1	2026-05-01	114
20	1	2026-05-01	64
21	1	2026-05-01	148
22	1	2026-05-01	46
23	1	2026-05-01	96
24	1	2026-05-01	228
25	1	2026-05-01	57
26	1	2026-05-01	84
27	1	2026-05-01	107
28	1	2026-05-01	39
29	1	2026-05-01	47
30	1	2026-05-01	169
31	1	2026-05-01	716
32	1	2026-05-01	32
33	1	2026-05-01	98
34	1	2026-05-01	48
35	1	2026-05-01	67
36	1	2026-05-01	96
37	1	2026-05-01	518
38	1	2026-05-01	170
39	1	2026-05-01	86
40	1	2026-05-01	29
1	2	2026-05-01	64
2	2	2026-05-01	111
3	2	2026-05-01	103
4	2	2026-05-01	213
5	2	2026-05-01	358
6	2	2026-05-01	420
7	2	2026-05-01	33
8	2	2026-05-01	62
9	2	2026-05-01	439
10	2	2026-05-01	131
11	2	2026-05-01	38
12	2	2026-05-01	536
13	2	2026-05-01	112
14	2	2026-05-01	69
15	2	2026-05-01	156
16	2	2026-05-01	274
17	2	2026-05-01	49
18	2	2026-05-01	179
19	2	2026-05-01	93
20	2	2026-05-01	60
21	2	2026-05-01	144
22	2	2026-05-01	47
23	2	2026-05-01	95
24	2	2026-05-01	254
25	2	2026-05-01	59
26	2	2026-05-01	78
27	2	2026-05-01	98
28	2	2026-05-01	36
29	2	2026-05-01	48
30	2	2026-05-01	178
31	2	2026-05-01	713
32	2	2026-05-01	31
33	2	2026-05-01	105
34	2	2026-05-01	46
35	2	2026-05-01	72
36	2	2026-05-01	89
37	2	2026-05-01	532
38	2	2026-05-01	178
39	2	2026-05-01	66
40	2	2026-05-01	41
1	3	2026-05-01	53
2	3	2026-05-01	106
3	3	2026-05-01	103
4	3	2026-05-01	219
5	3	2026-05-01	322
6	3	2026-05-01	458
7	3	2026-05-01	36
8	3	2026-05-01	70
9	3	2026-05-01	431
10	3	2026-05-01	114
11	3	2026-05-01	39
12	3	2026-05-01	578
13	3	2026-05-01	127
14	3	2026-05-01	74
15	3	2026-05-01	154
16	3	2026-05-01	255
17	3	2026-05-01	48
18	3	2026-05-01	185
19	3	2026-05-01	123
20	3	2026-05-01	66
21	3	2026-05-01	149
22	3	2026-05-01	51
23	3	2026-05-01	99
24	3	2026-05-01	206
25	3	2026-05-01	68
26	3	2026-05-01	83
27	3	2026-05-01	105
28	3	2026-05-01	36
29	3	2026-05-01	50
30	3	2026-05-01	187
31	3	2026-05-01	784
32	3	2026-05-01	35
33	3	2026-05-01	86
34	3	2026-05-01	50
35	3	2026-05-01	68
36	3	2026-05-01	94
37	3	2026-05-01	520
38	3	2026-05-01	180
39	3	2026-05-01	86
40	3	2026-05-01	38
1	1	2026-06-01	66
2	1	2026-06-01	134
3	1	2026-06-01	124
4	1	2026-06-01	259
5	1	2026-06-01	410
6	1	2026-06-01	494
7	1	2026-06-01	40
8	1	2026-06-01	97
9	1	2026-06-01	522
10	1	2026-06-01	134
11	1	2026-06-01	46
12	1	2026-06-01	668
13	1	2026-06-01	145
14	1	2026-06-01	80
15	1	2026-06-01	172
16	1	2026-06-01	239
17	1	2026-06-01	50
18	1	2026-06-01	226
19	1	2026-06-01	132
20	1	2026-06-01	64
21	1	2026-06-01	168
22	1	2026-06-01	48
23	1	2026-06-01	111
24	1	2026-06-01	281
25	1	2026-06-01	64
26	1	2026-06-01	86
27	1	2026-06-01	116
28	1	2026-06-01	36
29	1	2026-06-01	55
30	1	2026-06-01	231
31	1	2026-06-01	796
32	1	2026-06-01	40
33	1	2026-06-01	110
34	1	2026-06-01	55
35	1	2026-06-01	96
36	1	2026-06-01	90
37	1	2026-06-01	510
38	1	2026-06-01	173
39	1	2026-06-01	81
40	1	2026-06-01	35
1	2	2026-06-01	75
2	2	2026-06-01	142
3	2	2026-06-01	131
4	2	2026-06-01	260
5	2	2026-06-01	384
6	2	2026-06-01	470
7	2	2026-06-01	38
8	2	2026-06-01	79
9	2	2026-06-01	526
10	2	2026-06-01	129
11	2	2026-06-01	51
12	2	2026-06-01	669
13	2	2026-06-01	162
14	2	2026-06-01	89
15	2	2026-06-01	174
16	2	2026-06-01	267
17	2	2026-06-01	44
18	2	2026-06-01	197
19	2	2026-06-01	121
20	2	2026-06-01	69
21	2	2026-06-01	174
22	2	2026-06-01	59
23	2	2026-06-01	91
24	2	2026-06-01	264
25	2	2026-06-01	69
26	2	2026-06-01	86
27	2	2026-06-01	102
28	2	2026-06-01	36
29	2	2026-06-01	56
30	2	2026-06-01	174
31	2	2026-06-01	973
32	2	2026-06-01	38
33	2	2026-06-01	121
34	2	2026-06-01	63
35	2	2026-06-01	80
36	2	2026-06-01	104
37	2	2026-06-01	571
38	2	2026-06-01	199
39	2	2026-06-01	89
40	2	2026-06-01	38
1	3	2026-06-01	76
2	3	2026-06-01	137
3	3	2026-06-01	149
4	3	2026-06-01	250
5	3	2026-06-01	415
6	3	2026-06-01	530
7	3	2026-06-01	40
8	3	2026-06-01	84
9	3	2026-06-01	558
10	3	2026-06-01	133
11	3	2026-06-01	51
12	3	2026-06-01	782
13	3	2026-06-01	158
14	3	2026-06-01	87
15	3	2026-06-01	163
16	3	2026-06-01	275
17	3	2026-06-01	54
18	3	2026-06-01	231
19	3	2026-06-01	121
20	3	2026-06-01	55
21	3	2026-06-01	175
22	3	2026-06-01	55
23	3	2026-06-01	104
24	3	2026-06-01	250
25	3	2026-06-01	63
26	3	2026-06-01	95
27	3	2026-06-01	105
28	3	2026-06-01	37
29	3	2026-06-01	59
30	3	2026-06-01	228
31	3	2026-06-01	916
32	3	2026-06-01	33
33	3	2026-06-01	121
34	3	2026-06-01	67
35	3	2026-06-01	106
36	3	2026-06-01	110
37	3	2026-06-01	573
38	3	2026-06-01	173
39	3	2026-06-01	89
40	3	2026-06-01	34
1	1	2026-07-01	78
2	1	2026-07-01	142
3	1	2026-07-01	140
4	1	2026-07-01	310
5	1	2026-07-01	388
6	1	2026-07-01	561
7	1	2026-07-01	41
8	1	2026-07-01	82
9	1	2026-07-01	468
10	1	2026-07-01	156
11	1	2026-07-01	47
12	1	2026-07-01	690
13	1	2026-07-01	162
14	1	2026-07-01	74
15	1	2026-07-01	202
16	1	2026-07-01	282
17	1	2026-07-01	56
18	1	2026-07-01	208
19	1	2026-07-01	136
20	1	2026-07-01	63
21	1	2026-07-01	185
22	1	2026-07-01	54
23	1	2026-07-01	114
24	1	2026-07-01	275
25	1	2026-07-01	77
26	1	2026-07-01	93
27	1	2026-07-01	105
28	1	2026-07-01	34
29	1	2026-07-01	56
30	1	2026-07-01	194
31	1	2026-07-01	899
32	1	2026-07-01	41
33	1	2026-07-01	148
34	1	2026-07-01	56
35	1	2026-07-01	101
36	1	2026-07-01	97
37	1	2026-07-01	609
38	1	2026-07-01	169
39	1	2026-07-01	88
40	1	2026-07-01	38
1	2	2026-07-01	75
2	2	2026-07-01	124
3	2	2026-07-01	134
4	2	2026-07-01	227
5	2	2026-07-01	408
6	2	2026-07-01	456
7	2	2026-07-01	38
8	2	2026-07-01	85
9	2	2026-07-01	520
10	2	2026-07-01	145
11	2	2026-07-01	48
12	2	2026-07-01	749
13	2	2026-07-01	171
14	2	2026-07-01	94
15	2	2026-07-01	168
16	2	2026-07-01	258
17	2	2026-07-01	56
18	2	2026-07-01	188
19	2	2026-07-01	134
20	2	2026-07-01	72
21	2	2026-07-01	186
22	2	2026-07-01	45
23	2	2026-07-01	113
24	2	2026-07-01	286
25	2	2026-07-01	69
26	2	2026-07-01	97
27	2	2026-07-01	120
28	2	2026-07-01	38
29	2	2026-07-01	65
30	2	2026-07-01	213
31	2	2026-07-01	877
32	2	2026-07-01	45
33	2	2026-07-01	123
34	2	2026-07-01	66
35	2	2026-07-01	90
36	2	2026-07-01	117
37	2	2026-07-01	533
38	2	2026-07-01	205
39	2	2026-07-01	88
40	2	2026-07-01	36
1	3	2026-07-01	79
2	3	2026-07-01	136
3	3	2026-07-01	138
4	3	2026-07-01	254
5	3	2026-07-01	477
6	3	2026-07-01	547
7	3	2026-07-01	44
8	3	2026-07-01	85
9	3	2026-07-01	461
10	3	2026-07-01	162
11	3	2026-07-01	51
12	3	2026-07-01	711
13	3	2026-07-01	136
14	3	2026-07-01	103
15	3	2026-07-01	186
16	3	2026-07-01	282
17	3	2026-07-01	55
18	3	2026-07-01	185
19	3	2026-07-01	127
20	3	2026-07-01	61
21	3	2026-07-01	166
22	3	2026-07-01	56
23	3	2026-07-01	111
24	3	2026-07-01	269
25	3	2026-07-01	74
26	3	2026-07-01	89
27	3	2026-07-01	101
28	3	2026-07-01	43
29	3	2026-07-01	61
30	3	2026-07-01	234
31	3	2026-07-01	951
32	3	2026-07-01	37
33	3	2026-07-01	126
34	3	2026-07-01	57
35	3	2026-07-01	81
36	3	2026-07-01	117
37	3	2026-07-01	558
38	3	2026-07-01	189
39	3	2026-07-01	95
40	3	2026-07-01	44
\.
COPY cycle_counts (count_id, count_date, dc_id, product_id, system_qty, counted_qty) FROM stdin;
1	2025-11-18	1	1	58	58
2	2025-11-18	1	2	174	174
3	2025-11-18	1	3	108	108
4	2025-11-18	1	4	84	84
5	2025-11-18	1	5	220	220
6	2025-11-18	1	6	537	537
7	2025-11-18	1	7	53	53
8	2025-11-18	1	8	76	76
9	2025-11-18	1	9	352	352
10	2025-11-18	1	10	144	144
11	2025-11-18	1	11	29	29
12	2025-11-18	1	12	506	506
13	2025-11-18	1	13	159	159
14	2025-11-18	1	14	72	71
15	2025-11-18	1	15	133	133
16	2025-11-18	1	16	378	378
17	2025-11-18	1	17	92	92
18	2025-11-18	1	18	440	440
19	2025-11-18	1	19	136	136
20	2025-11-18	1	20	122	122
21	2025-11-18	1	21	210	210
22	2025-11-18	1	22	49	49
23	2025-11-18	1	23	107	107
24	2025-11-18	1	24	420	420
25	2025-11-18	1	25	26	27
26	2025-11-18	1	26	236	236
27	2025-11-18	1	27	92	92
28	2025-11-18	1	28	112	112
29	2025-11-18	1	29	114	114
30	2025-11-18	1	30	375	376
31	2025-11-18	1	31	731	731
32	2025-11-18	1	32	41	41
33	2025-11-18	1	33	94	94
34	2025-11-18	1	34	46	46
35	2025-11-18	1	35	73	73
36	2025-11-18	1	36	227	227
37	2025-11-18	1	37	795	795
38	2025-11-18	1	38	102	102
39	2025-11-18	1	39	110	110
40	2025-11-18	1	40	77	77
41	2025-11-20	2	1	54	54
42	2025-11-20	2	2	130	128
43	2025-11-20	2	3	96	96
44	2025-11-20	2	4	144	144
45	2025-11-20	2	5	77	77
46	2025-11-20	2	6	191	191
47	2025-11-20	2	7	26	28
48	2025-11-20	2	8	50	50
49	2025-11-20	2	9	280	280
50	2025-11-20	2	10	157	157
51	2025-11-20	2	11	40	40
52	2025-11-20	2	12	529	529
53	2025-11-20	2	13	170	170
54	2025-11-20	2	14	111	111
55	2025-11-20	2	15	170	170
56	2025-11-20	2	16	354	354
57	2025-11-20	2	17	47	47
58	2025-11-20	2	18	282	282
59	2025-11-20	2	19	214	214
60	2025-11-20	2	20	96	96
61	2025-11-20	2	21	75	75
62	2025-11-20	2	22	46	46
63	2025-11-20	2	23	0	0
64	2025-11-20	2	24	226	226
65	2025-11-20	2	25	23	23
66	2025-11-20	2	26	185	185
67	2025-11-20	2	27	161	161
68	2025-11-20	2	28	67	67
69	2025-11-20	2	29	137	137
70	2025-11-20	2	30	200	200
71	2025-11-20	2	31	886	886
72	2025-11-20	2	32	42	42
73	2025-11-20	2	33	115	115
74	2025-11-20	2	34	40	40
75	2025-11-20	2	35	96	96
76	2025-11-20	2	36	187	187
77	2025-11-20	2	37	397	397
78	2025-11-20	2	38	121	121
79	2025-11-20	2	39	82	82
80	2025-11-20	2	40	68	68
81	2025-12-02	3	1	44	44
82	2025-12-02	3	2	90	90
83	2025-12-02	3	3	60	60
84	2025-12-02	3	4	277	276
85	2025-12-02	3	5	240	240
86	2025-12-02	3	6	112	112
87	2025-12-02	3	7	59	59
88	2025-12-02	3	8	81	81
89	2025-12-02	3	9	384	384
90	2025-12-02	3	10	79	79
91	2025-12-02	3	11	71	71
92	2025-12-02	3	12	445	445
93	2025-12-02	3	13	123	123
94	2025-12-02	3	14	51	52
95	2025-12-02	3	15	232	232
96	2025-12-02	3	16	243	243
97	2025-12-02	3	17	100	100
98	2025-12-02	3	18	496	496
99	2025-12-02	3	19	148	148
100	2025-12-02	3	20	51	51
101	2025-12-02	3	21	130	130
102	2025-12-02	3	22	61	59
103	2025-12-02	3	23	100	100
104	2025-12-02	3	24	399	399
105	2025-12-02	3	25	50	50
106	2025-12-02	3	26	182	182
107	2025-12-02	3	27	166	166
108	2025-12-02	3	28	79	79
109	2025-12-02	3	29	97	95
110	2025-12-02	3	30	273	273
111	2025-12-02	3	31	507	507
112	2025-12-02	3	32	1	1
113	2025-12-02	3	33	33	33
114	2025-12-02	3	34	21	21
115	2025-12-02	3	35	69	69
116	2025-12-02	3	36	225	225
117	2025-12-02	3	37	248	248
118	2025-12-02	3	38	102	102
119	2025-12-02	3	39	68	68
120	2025-12-02	3	40	32	32
121	2026-02-15	1	1	17	17
122	2026-02-15	1	2	132	132
123	2026-02-15	1	3	84	84
124	2026-02-15	1	4	132	132
125	2026-02-15	1	5	360	360
126	2026-02-15	1	6	153	153
127	2026-02-15	1	7	35	35
128	2026-02-15	1	8	70	70
129	2026-02-15	1	9	184	184
130	2026-02-15	1	10	120	120
131	2026-02-15	1	11	35	35
132	2026-02-15	1	12	674	674
133	2026-02-15	1	13	15	14
134	2026-02-15	1	14	60	60
135	2026-02-15	1	15	97	97
136	2026-02-15	1	16	414	405
137	2026-02-15	1	17	48	44
138	2026-02-15	1	18	440	418
139	2026-02-15	1	19	144	144
140	2026-02-15	1	20	50	50
141	2026-02-15	1	21	48	50
142	2026-02-15	1	22	109	109
143	2026-02-15	1	23	120	120
144	2026-02-15	1	24	300	300
145	2026-02-15	1	25	0	0
146	2026-02-15	1	26	171	171
147	2026-02-15	1	27	32	32
148	2026-02-15	1	28	112	112
149	2026-02-15	1	29	72	72
150	2026-02-15	1	30	471	471
151	2026-02-15	1	31	923	923
152	2026-02-15	1	32	41	41
153	2026-02-15	1	33	24	24
154	2026-02-15	1	34	84	84
155	2026-02-15	1	35	133	133
156	2026-02-15	1	36	251	251
157	2026-02-15	1	37	315	315
158	2026-02-15	1	38	180	178
159	2026-02-15	1	39	128	128
160	2026-02-15	1	40	71	71
161	2026-02-20	2	1	66	66
162	2026-02-20	2	2	76	76
163	2026-02-20	2	3	84	84
164	2026-02-20	2	4	240	240
165	2026-02-20	2	5	0	0
166	2026-02-20	2	6	503	503
167	2026-02-20	2	7	44	44
168	2026-02-20	2	8	80	80
169	2026-02-20	2	9	304	304
170	2026-02-20	2	10	205	205
171	2026-02-20	2	11	34	34
172	2026-02-20	2	12	432	432
173	2026-02-20	2	13	158	158
174	2026-02-20	2	14	96	96
175	2026-02-20	2	15	2	2
176	2026-02-20	2	16	306	306
177	2026-02-20	2	17	17	17
178	2026-02-20	2	18	312	313
179	2026-02-20	2	19	94	94
180	2026-02-20	2	20	108	108
181	2026-02-20	2	21	96	96
182	2026-02-20	2	22	60	60
183	2026-02-20	2	23	156	156
184	2026-02-20	2	24	226	226
185	2026-02-20	2	25	36	36
186	2026-02-20	2	26	137	137
187	2026-02-20	2	27	161	161
188	2026-02-20	2	28	24	24
189	2026-02-20	2	29	149	149
190	2026-02-20	2	30	120	120
191	2026-02-20	2	31	528	528
192	2026-02-20	2	32	24	24
193	2026-02-20	2	33	0	0
194	2026-02-20	2	34	76	76
195	2026-02-20	2	35	12	11
196	2026-02-20	2	36	139	139
197	2026-02-20	2	37	589	589
198	2026-02-20	2	38	240	240
199	2026-02-20	2	39	130	130
200	2026-02-20	2	40	90	90
201	2026-03-02	3	1	44	44
202	2026-03-02	3	2	90	90
203	2026-03-02	3	3	156	156
204	2026-03-02	3	4	145	145
205	2026-03-02	3	5	480	480
206	2026-03-02	3	6	384	384
207	2026-03-02	3	7	41	41
208	2026-03-02	3	8	51	51
209	2026-03-02	3	9	480	480
210	2026-03-02	3	10	223	223
211	2026-03-02	3	11	41	41
212	2026-03-02	3	12	205	205
213	2026-03-02	3	13	96	96
214	2026-03-02	3	14	63	63
215	2026-03-02	3	15	160	160
216	2026-03-02	3	16	339	339
217	2026-03-02	3	17	64	64
218	2026-03-02	3	18	432	432
219	2026-03-02	3	19	144	144
220	2026-03-02	3	20	84	85
221	2026-03-02	3	21	240	240
222	2026-03-02	3	22	79	79
223	2026-03-02	3	23	108	107
224	2026-03-02	3	24	351	351
225	2026-03-02	3	25	48	48
226	2026-03-02	3	26	164	164
227	2026-03-02	3	27	190	190
228	2026-03-02	3	28	55	55
229	2026-03-02	3	29	133	133
230	2026-03-02	3	30	513	513
231	2026-03-02	3	31	267	267
232	2026-03-02	3	32	42	42
233	2026-03-02	3	33	72	72
234	2026-03-02	3	34	12	12
235	2026-03-02	3	35	129	129
236	2026-03-02	3	36	177	177
237	2026-03-02	3	37	483	483
238	2026-03-02	3	38	270	270
239	2026-03-02	3	39	122	124
240	2026-03-02	3	40	66	66
241	2026-05-15	2	1	30	30
242	2026-05-15	2	2	112	112
243	2026-05-15	2	3	168	168
244	2026-05-15	2	4	235	235
245	2026-05-15	2	5	312	312
246	2026-05-15	2	6	431	431
247	2026-05-15	2	7	20	20
248	2026-05-15	2	8	80	80
249	2026-05-15	2	9	160	160
250	2026-05-15	2	10	109	107
251	2026-05-15	2	11	52	52
252	2026-05-15	2	12	480	480
253	2026-05-15	2	13	156	156
254	2026-05-15	2	14	24	24
255	2026-05-15	2	15	122	121
256	2026-05-15	2	16	414	414
257	2026-05-15	2	17	41	41
258	2026-05-15	2	18	432	432
259	2026-05-15	2	19	214	214
260	2026-05-15	2	20	114	116
261	2026-05-15	2	21	72	72
262	2026-05-15	2	22	72	72
263	2026-05-15	2	23	36	34
264	2026-05-15	2	24	298	296
265	2026-05-15	2	25	78	78
266	2026-05-15	2	26	12	12
267	2026-05-15	2	27	53	53
268	2026-05-15	2	28	36	36
269	2026-05-15	2	29	47	45
270	2026-05-15	2	30	0	0
271	2026-05-15	2	31	504	504
272	2026-05-15	2	32	48	48
273	2026-05-15	2	33	108	108
274	2026-05-15	2	34	40	40
275	2026-05-15	2	35	84	84
276	2026-05-15	2	36	48	48
277	2026-05-15	2	37	637	637
278	2026-05-15	2	38	276	276
279	2026-05-15	2	39	64	64
280	2026-05-15	2	40	78	78
281	2026-05-22	3	1	78	78
282	2026-05-22	3	2	78	78
283	2026-05-22	3	3	120	120
284	2026-05-22	3	4	168	168
285	2026-05-22	3	5	360	360
286	2026-05-22	3	6	0	0
287	2026-05-22	3	7	42	42
288	2026-05-22	3	8	0	0
289	2026-05-22	3	9	120	120
290	2026-05-22	3	10	0	0
291	2026-05-22	3	11	35	35
292	2026-05-22	3	12	565	565
293	2026-05-22	3	13	84	84
294	2026-05-22	3	14	0	0
295	2026-05-22	3	15	124	124
296	2026-05-22	3	16	219	219
297	2026-05-22	3	17	64	64
298	2026-05-22	3	18	144	146
299	2026-05-22	3	19	96	96
300	2026-05-22	3	20	102	102
301	2026-05-22	3	21	0	0
302	2026-05-22	3	22	109	109
303	2026-05-22	3	23	0	0
304	2026-05-22	3	24	303	304
305	2026-05-22	3	25	0	0
306	2026-05-22	3	26	362	362
307	2026-05-22	3	27	382	382
308	2026-05-22	3	28	67	67
309	2026-05-22	3	29	271	271
310	2026-05-22	3	30	801	801
311	2026-05-22	3	31	336	337
312	2026-05-22	3	32	30	30
313	2026-05-22	3	33	66	66
314	2026-05-22	3	34	96	96
315	2026-05-22	3	35	57	57
316	2026-05-22	3	36	57	57
317	2026-05-22	3	37	600	600
318	2026-05-22	3	38	114	114
319	2026-05-22	3	39	86	86
320	2026-05-22	3	40	24	24
321	2026-07-20	1	16	361	20
322	2026-07-20	1	17	95	24
323	2026-07-20	1	18	297	0
324	2026-07-20	1	19	168	168
325	2026-07-20	1	20	140	140
\.
COMMIT;
ANALYZE;
