--
-- PostgreSQL database dump
--

\restrict gctp4mC3gOV0C5gedAZToCK15KE77suZmylTctcH1XvJzm4YmGOFbbBLbMpeYHM

-- Dumped from database version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)
-- Dumped by pg_dump version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fn_after_txn(); Type: FUNCTION; Schema: public; Owner: inv_admin
--

CREATE FUNCTION public.fn_after_txn() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  total INT;
  rp    INT;
BEGIN
  IF NEW.txn_type IN ('SALE','WASTE') AND NEW.batch_id IS NOT NULL THEN
    UPDATE stock_batches SET quantity = quantity - NEW.quantity
    WHERE batch_id = NEW.batch_id;
  ELSIF NEW.txn_type = 'RECEIPT' AND NEW.batch_id IS NOT NULL THEN
    UPDATE stock_batches SET quantity = quantity + NEW.quantity
    WHERE batch_id = NEW.batch_id;
  END IF;

  SELECT COALESCE(SUM(quantity),0) INTO total
  FROM stock_batches WHERE product_id = NEW.product_id;

  SELECT reorder_point INTO rp
  FROM reorder_rules WHERE product_id = NEW.product_id;

  IF rp IS NOT NULL AND total <= rp THEN
    IF NOT EXISTS (
      SELECT 1 FROM alerts
      WHERE product_id = NEW.product_id
        AND alert_type = 'LOW_STOCK'
        AND is_resolved = FALSE
    ) THEN
      INSERT INTO alerts(product_id, alert_type, message)
      VALUES (NEW.product_id, 'LOW_STOCK',
              'Stock ' || total || ' is at or below reorder point ' || rp);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_after_txn() OWNER TO inv_admin;

--
-- Name: fn_po_received(); Type: FUNCTION; Schema: public; Owner: inv_admin
--

CREATE FUNCTION public.fn_po_received() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  item         RECORD;
  v_batch_id   INT;
  v_perishable BOOLEAN;
  v_expiry     DATE;
  v_total      INT;
  v_rp         INT;
BEGIN
  FOR item IN
    SELECT product_id, quantity FROM po_items WHERE po_id = NEW.po_id
  LOOP
    SELECT is_perishable INTO v_perishable
    FROM products WHERE product_id = item.product_id;

    -- No shelf-life column exists, so perishables get a default of 14 days
    v_expiry := CASE WHEN v_perishable THEN CURRENT_DATE + 14 ELSE NULL END;

    -- Batch starts at 0; the RECEIPT transaction below adds the quantity
    INSERT INTO stock_batches(product_id, quantity, received_on, expiry_date)
    VALUES (item.product_id, 0, CURRENT_DATE, v_expiry)
    RETURNING batch_id INTO v_batch_id;

    INSERT INTO transactions(product_id, batch_id, txn_type, quantity, user_id)
    VALUES (item.product_id, v_batch_id, 'RECEIPT', item.quantity, NEW.approved_by);

    -- Close the low-stock alert if the product has recovered
    SELECT COALESCE(SUM(quantity), 0) INTO v_total
    FROM stock_batches WHERE product_id = item.product_id;

    SELECT reorder_point INTO v_rp
    FROM reorder_rules WHERE product_id = item.product_id;

    IF v_rp IS NULL OR v_total > v_rp THEN
      UPDATE alerts SET is_resolved = TRUE
      WHERE product_id = item.product_id
        AND alert_type = 'LOW_STOCK'
        AND is_resolved = FALSE;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_po_received() OWNER TO inv_admin;

--
-- Name: sp_generate_po(integer, text); Type: FUNCTION; Schema: public; Owner: inv_admin
--

CREATE FUNCTION public.sp_generate_po(p_product_id integer, p_reason text DEFAULT 'Auto-generated reorder'::text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_supplier_id INT;
  v_cost        NUMERIC(10,2);
  v_qty         INT;
  v_po_id       INT;
BEGIN
  SELECT supplier_id, cost_price INTO v_supplier_id, v_cost
  FROM product_suppliers
  WHERE product_id = p_product_id AND is_preferred;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No preferred supplier for product %', p_product_id;
  END IF;

  SELECT reorder_qty INTO v_qty
  FROM reorder_rules WHERE product_id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No reorder rule for product %', p_product_id;
  END IF;

  -- Do not create a duplicate if the product is already on an open PO
  SELECT po.po_id INTO v_po_id
  FROM purchase_orders po
  JOIN po_items i ON i.po_id = po.po_id
  WHERE i.product_id = p_product_id
    AND po.status IN ('DRAFT','APPROVED','SENT')
  ORDER BY po.po_id DESC
  LIMIT 1;

  IF FOUND THEN
    RAISE NOTICE 'Product % is already on open PO %', p_product_id, v_po_id;
    RETURN v_po_id;
  END IF;

  INSERT INTO purchase_orders(supplier_id, status, created_by, reason)
  VALUES (v_supplier_id, 'DRAFT', 'AGENT', p_reason)
  RETURNING po_id INTO v_po_id;

  INSERT INTO po_items(po_id, product_id, quantity, unit_cost)
  VALUES (v_po_id, p_product_id, v_qty, v_cost);

  RETURN v_po_id;
END;
$$;


ALTER FUNCTION public.sp_generate_po(p_product_id integer, p_reason text) OWNER TO inv_admin;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: alerts; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.alerts (
    alert_id integer NOT NULL,
    product_id integer,
    alert_type character varying(20) NOT NULL,
    message text NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    is_resolved boolean DEFAULT false
);


ALTER TABLE public.alerts OWNER TO inv_admin;

--
-- Name: alerts_alert_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.alerts_alert_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.alerts_alert_id_seq OWNER TO inv_admin;

--
-- Name: alerts_alert_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.alerts_alert_id_seq OWNED BY public.alerts.alert_id;


--
-- Name: categories; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.categories (
    category_id integer NOT NULL,
    name character varying(80) NOT NULL
);


ALTER TABLE public.categories OWNER TO inv_admin;

--
-- Name: categories_category_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.categories_category_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.categories_category_id_seq OWNER TO inv_admin;

--
-- Name: categories_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.categories_category_id_seq OWNED BY public.categories.category_id;


--
-- Name: demand_forecasts; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.demand_forecasts (
    forecast_id integer NOT NULL,
    product_id integer NOT NULL,
    forecast_date date NOT NULL,
    predicted_qty numeric(10,2) NOT NULL,
    model_used character varying(30)
);


ALTER TABLE public.demand_forecasts OWNER TO inv_admin;

--
-- Name: demand_forecasts_forecast_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.demand_forecasts_forecast_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.demand_forecasts_forecast_id_seq OWNER TO inv_admin;

--
-- Name: demand_forecasts_forecast_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.demand_forecasts_forecast_id_seq OWNED BY public.demand_forecasts.forecast_id;


--
-- Name: po_items; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.po_items (
    po_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity integer NOT NULL,
    unit_cost numeric(10,2) NOT NULL,
    CONSTRAINT po_items_quantity_check CHECK ((quantity > 0))
);


ALTER TABLE public.po_items OWNER TO inv_admin;

--
-- Name: product_suppliers; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.product_suppliers (
    product_id integer NOT NULL,
    supplier_id integer NOT NULL,
    cost_price numeric(10,2) NOT NULL,
    lead_time_days integer NOT NULL,
    is_preferred boolean DEFAULT false,
    CONSTRAINT product_suppliers_lead_time_days_check CHECK ((lead_time_days >= 0))
);


ALTER TABLE public.product_suppliers OWNER TO inv_admin;

--
-- Name: products; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.products (
    product_id integer NOT NULL,
    sku character varying(40) NOT NULL,
    name character varying(120) NOT NULL,
    category_id integer NOT NULL,
    unit character varying(20) NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    is_perishable boolean DEFAULT false,
    is_active boolean DEFAULT true,
    CONSTRAINT products_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


ALTER TABLE public.products OWNER TO inv_admin;

--
-- Name: products_product_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.products_product_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_product_id_seq OWNER TO inv_admin;

--
-- Name: products_product_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.products_product_id_seq OWNED BY public.products.product_id;


--
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.purchase_orders (
    po_id integer NOT NULL,
    supplier_id integer NOT NULL,
    status character varying(15) DEFAULT 'DRAFT'::character varying NOT NULL,
    created_by character varying(10) DEFAULT 'AGENT'::character varying NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    approved_by integer,
    reason text,
    CONSTRAINT purchase_orders_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'APPROVED'::character varying, 'REJECTED'::character varying, 'SENT'::character varying, 'RECEIVED'::character varying])::text[])))
);


ALTER TABLE public.purchase_orders OWNER TO inv_admin;

--
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.purchase_orders_po_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchase_orders_po_id_seq OWNER TO inv_admin;

--
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.purchase_orders_po_id_seq OWNED BY public.purchase_orders.po_id;


--
-- Name: reorder_rules; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.reorder_rules (
    product_id integer NOT NULL,
    safety_stock integer DEFAULT 0 NOT NULL,
    reorder_point integer NOT NULL,
    reorder_qty integer NOT NULL,
    auto_order boolean DEFAULT false
);


ALTER TABLE public.reorder_rules OWNER TO inv_admin;

--
-- Name: stock_batches; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.stock_batches (
    batch_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity integer NOT NULL,
    received_on date DEFAULT CURRENT_DATE NOT NULL,
    expiry_date date,
    CONSTRAINT stock_batches_quantity_check CHECK ((quantity >= 0))
);


ALTER TABLE public.stock_batches OWNER TO inv_admin;

--
-- Name: stock_batches_batch_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.stock_batches_batch_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.stock_batches_batch_id_seq OWNER TO inv_admin;

--
-- Name: stock_batches_batch_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.stock_batches_batch_id_seq OWNED BY public.stock_batches.batch_id;


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.suppliers (
    supplier_id integer NOT NULL,
    name character varying(120) NOT NULL,
    phone character varying(20),
    email character varying(150)
);


ALTER TABLE public.suppliers OWNER TO inv_admin;

--
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.suppliers_supplier_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.suppliers_supplier_id_seq OWNER TO inv_admin;

--
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.suppliers_supplier_id_seq OWNED BY public.suppliers.supplier_id;


--
-- Name: transactions; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.transactions (
    txn_id bigint NOT NULL,
    product_id integer NOT NULL,
    batch_id integer,
    txn_type character varying(10) NOT NULL,
    quantity integer NOT NULL,
    txn_time timestamp without time zone DEFAULT now() NOT NULL,
    user_id integer,
    CONSTRAINT transactions_txn_type_check CHECK (((txn_type)::text = ANY ((ARRAY['SALE'::character varying, 'RECEIPT'::character varying, 'WASTE'::character varying, 'ADJUST'::character varying])::text[])))
);


ALTER TABLE public.transactions OWNER TO inv_admin;

--
-- Name: transactions_txn_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.transactions_txn_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.transactions_txn_id_seq OWNER TO inv_admin;

--
-- Name: transactions_txn_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.transactions_txn_id_seq OWNED BY public.transactions.txn_id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: inv_admin
--

CREATE TABLE public.users (
    user_id integer NOT NULL,
    name character varying(100) NOT NULL,
    email character varying(150) NOT NULL,
    role character varying(20) NOT NULL,
    password_hash text NOT NULL,
    CONSTRAINT users_role_check CHECK (((role)::text = ANY ((ARRAY['admin'::character varying, 'manager'::character varying, 'staff'::character varying])::text[])))
);


ALTER TABLE public.users OWNER TO inv_admin;

--
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: public; Owner: inv_admin
--

CREATE SEQUENCE public.users_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_user_id_seq OWNER TO inv_admin;

--
-- Name: users_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: inv_admin
--

ALTER SEQUENCE public.users_user_id_seq OWNED BY public.users.user_id;


--
-- Name: v_current_stock; Type: VIEW; Schema: public; Owner: inv_admin
--

CREATE VIEW public.v_current_stock AS
 SELECT p.product_id,
    p.name,
    c.name AS category,
    COALESCE(sum(b.quantity), (0)::bigint) AS total_qty,
    r.reorder_point
   FROM (((public.products p
     JOIN public.categories c ON ((c.category_id = p.category_id)))
     LEFT JOIN public.stock_batches b ON ((b.product_id = p.product_id)))
     LEFT JOIN public.reorder_rules r ON ((r.product_id = p.product_id)))
  GROUP BY p.product_id, p.name, c.name, r.reorder_point;


ALTER VIEW public.v_current_stock OWNER TO inv_admin;

--
-- Name: v_daily_sales; Type: VIEW; Schema: public; Owner: inv_admin
--

CREATE VIEW public.v_daily_sales AS
 SELECT product_id,
    date(txn_time) AS day,
    sum(quantity) AS units_sold
   FROM public.transactions
  WHERE ((txn_type)::text = 'SALE'::text)
  GROUP BY product_id, (date(txn_time));


ALTER VIEW public.v_daily_sales OWNER TO inv_admin;

--
-- Name: v_daily_sales_full; Type: VIEW; Schema: public; Owner: inv_admin
--

CREATE VIEW public.v_daily_sales_full AS
 SELECT p.product_id,
    (d.day)::date AS day,
    COALESCE(s.units_sold, (0)::bigint) AS units_sold
   FROM ((public.products p
     CROSS JOIN LATERAL generate_series((COALESCE(( SELECT min(v_daily_sales.day) AS min
           FROM public.v_daily_sales), CURRENT_DATE))::timestamp with time zone, (CURRENT_DATE)::timestamp with time zone, '1 day'::interval) d(day))
     LEFT JOIN public.v_daily_sales s ON (((s.product_id = p.product_id) AND (s.day = (d.day)::date))));


ALTER VIEW public.v_daily_sales_full OWNER TO inv_admin;

--
-- Name: v_near_expiry; Type: VIEW; Schema: public; Owner: inv_admin
--

CREATE VIEW public.v_near_expiry AS
 SELECT p.name,
    b.batch_id,
    b.quantity,
    b.expiry_date
   FROM (public.stock_batches b
     JOIN public.products p USING (product_id))
  WHERE ((b.expiry_date <= (CURRENT_DATE + 7)) AND (b.quantity > 0));


ALTER VIEW public.v_near_expiry OWNER TO inv_admin;

--
-- Name: alerts alert_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.alerts ALTER COLUMN alert_id SET DEFAULT nextval('public.alerts_alert_id_seq'::regclass);


--
-- Name: categories category_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.categories ALTER COLUMN category_id SET DEFAULT nextval('public.categories_category_id_seq'::regclass);


--
-- Name: demand_forecasts forecast_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.demand_forecasts ALTER COLUMN forecast_id SET DEFAULT nextval('public.demand_forecasts_forecast_id_seq'::regclass);


--
-- Name: products product_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.products ALTER COLUMN product_id SET DEFAULT nextval('public.products_product_id_seq'::regclass);


--
-- Name: purchase_orders po_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.purchase_orders ALTER COLUMN po_id SET DEFAULT nextval('public.purchase_orders_po_id_seq'::regclass);


--
-- Name: stock_batches batch_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.stock_batches ALTER COLUMN batch_id SET DEFAULT nextval('public.stock_batches_batch_id_seq'::regclass);


--
-- Name: suppliers supplier_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.suppliers ALTER COLUMN supplier_id SET DEFAULT nextval('public.suppliers_supplier_id_seq'::regclass);


--
-- Name: transactions txn_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.transactions ALTER COLUMN txn_id SET DEFAULT nextval('public.transactions_txn_id_seq'::regclass);


--
-- Name: users user_id; Type: DEFAULT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.users ALTER COLUMN user_id SET DEFAULT nextval('public.users_user_id_seq'::regclass);


--
-- Data for Name: alerts; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.alerts (alert_id, product_id, alert_type, message, created_at, is_resolved) FROM stdin;
1	13	LOW_STOCK	Stock 12 is at or below reorder point 50	2026-10-23 18:45:13.758873	f
2	25	LOW_STOCK	Stock 11 is at or below reorder point 59	2026-10-23 18:45:13.758873	f
3	26	LOW_STOCK	Stock 64 is at or below reorder point 88	2026-10-23 18:45:13.758873	f
4	32	LOW_STOCK	Stock 86 is at or below reorder point 97	2026-10-23 18:45:13.758873	f
5	45	LOW_STOCK	Stock 57 is at or below reorder point 121	2026-10-23 18:45:13.758873	f
6	46	LOW_STOCK	Stock 17 is at or below reorder point 72	2026-10-23 18:45:13.758873	f
7	16	NEAR_EXPIRY	Batch 49 expires on 2026-10-27	2026-10-23 18:45:13.758873	f
8	11	NEAR_EXPIRY	Batch 50 expires on 2026-10-27	2026-10-23 18:45:13.758873	f
9	19	NEAR_EXPIRY	Batch 51 expires on 2026-10-26	2026-10-23 18:45:13.758873	f
10	20	NEAR_EXPIRY	Batch 52 expires on 2026-10-26	2026-10-23 18:45:13.758873	f
11	9	NEAR_EXPIRY	Batch 53 expires on 2026-10-25	2026-10-23 18:45:13.758873	f
\.


--
-- Data for Name: categories; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.categories (category_id, name) FROM stdin;
1	Beverages
2	Dairy & Eggs
3	Bakery
4	Snacks
5	Grains & Staples
6	Household
\.


--
-- Data for Name: demand_forecasts; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.demand_forecasts (forecast_id, product_id, forecast_date, predicted_qty, model_used) FROM stdin;
\.


--
-- Data for Name: po_items; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.po_items (po_id, product_id, quantity, unit_cost) FROM stdin;
\.


--
-- Data for Name: product_suppliers; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.product_suppliers (product_id, supplier_id, cost_price, lead_time_days, is_preferred) FROM stdin;
1	3	66.48	3	t
2	1	66.81	2	t
2	4	75.69	3	f
2	5	76.90	2	f
3	2	72.89	6	t
3	4	83.57	2	f
4	3	87.66	3	t
4	2	68.72	4	f
5	5	24.30	2	t
5	3	20.36	6	f
6	5	19.31	6	t
6	3	18.42	2	f
7	2	81.46	2	t
8	2	65.88	4	t
8	3	75.99	4	f
9	2	38.13	2	t
9	5	41.62	3	f
9	1	41.58	1	f
10	1	215.72	2	t
11	3	73.39	2	t
11	2	74.75	3	f
11	5	67.85	2	f
12	5	161.61	3	t
12	4	190.04	1	f
13	1	137.79	1	t
14	5	218.50	2	t
14	1	228.03	2	f
15	1	270.76	3	t
16	3	81.31	2	t
16	1	101.79	1	f
16	2	84.02	3	f
17	1	68.58	3	t
17	3	64.11	1	f
17	4	67.26	1	f
18	5	78.05	2	t
19	2	87.30	1	t
19	1	69.46	1	f
20	2	79.47	2	t
20	5	65.75	1	f
20	3	68.93	3	f
21	2	82.15	3	t
21	3	87.77	2	f
21	5	70.25	2	f
22	5	14.03	3	t
23	1	12.17	1	t
23	2	11.08	1	f
23	5	11.56	2	f
24	5	54.54	2	t
24	4	44.32	1	f
24	1	49.15	3	f
25	1	65.70	5	t
25	5	57.25	2	f
25	4	62.32	3	f
26	4	62.09	2	t
26	2	55.86	6	f
27	1	126.56	3	t
28	1	60.92	5	t
28	2	66.26	5	f
29	5	42.33	3	t
29	4	45.96	2	f
29	1	39.30	6	f
30	4	12.85	6	t
30	2	12.80	3	f
30	1	15.33	2	f
31	2	59.30	2	t
31	1	61.84	6	f
31	3	68.24	4	f
32	2	85.94	5	t
32	3	90.58	7	f
33	1	405.75	5	t
34	5	419.17	3	t
35	2	369.65	4	t
36	3	334.49	6	t
36	1	314.64	7	f
36	5	330.95	3	f
37	3	328.58	4	t
38	3	95.25	2	t
38	4	117.95	5	f
38	2	92.52	2	f
39	2	294.07	6	t
39	4	238.84	6	f
40	2	404.44	6	t
40	1	356.05	5	f
40	5	383.05	4	f
41	2	197.13	7	t
42	5	241.86	3	t
42	2	242.91	3	f
43	4	55.22	4	t
43	2	54.33	7	f
44	2	204.16	5	t
45	2	78.32	4	t
45	4	67.92	4	f
45	5	68.90	6	f
46	1	86.44	4	t
47	4	29.03	4	t
47	3	26.32	6	f
47	5	26.95	6	f
48	5	189.36	6	t
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.products (product_id, sku, name, category_id, unit, unit_price, is_perishable, is_active) FROM stdin;
1	SKU001	Mineral Water 1L	1	pcs	103.13	f	t
2	SKU002	Orange Juice 1L	1	pcs	107.97	f	t
3	SKU003	Cola 500ml	1	pcs	111.17	f	t
4	SKU004	Green Tea Box	1	pcs	110.76	f	t
5	SKU005	Instant Coffee 100g	1	pcs	32.57	f	t
6	SKU006	Energy Drink 250ml	1	pcs	30.24	f	t
7	SKU007	Mango Drink 200ml	1	pcs	120.50	f	t
8	SKU008	Soda Water 750ml	1	pcs	102.64	f	t
9	SKU009	Milk 1L	2	pcs	56.42	t	t
10	SKU010	Curd 500g	2	pcs	317.12	t	t
11	SKU011	Butter 100g	2	pcs	108.06	t	t
12	SKU012	Cheese Slices	2	pcs	237.71	t	t
13	SKU013	Paneer 200g	2	pcs	218.52	t	t
14	SKU014	Eggs Tray 12	2	pcs	323.07	t	t
15	SKU015	Yogurt Cup	2	pcs	348.49	t	t
16	SKU016	Cream 200ml	2	pcs	128.73	t	t
17	SKU017	White Bread	3	pcs	95.01	t	t
18	SKU018	Brown Bread	3	pcs	111.86	t	t
19	SKU019	Burger Buns	3	pcs	112.56	t	t
20	SKU020	Croissant	3	pcs	100.68	t	t
21	SKU021	Cake Slice	3	pcs	112.54	t	t
22	SKU022	Muffin	3	pcs	21.72	t	t
23	SKU023	Pav Pack	3	pcs	15.76	t	t
24	SKU024	Donut	3	pcs	71.62	t	t
25	SKU025	Potato Chips	4	pcs	88.11	f	t
26	SKU026	Salted Peanuts	4	pcs	90.16	f	t
27	SKU027	Chocolate Bar	4	pcs	199.86	f	t
28	SKU028	Namkeen Mix	4	pcs	101.46	f	t
29	SKU029	Popcorn Pack	4	pcs	64.20	f	t
30	SKU030	Cream Biscuits	4	pcs	20.86	f	t
31	SKU031	Rusk Pack	4	pcs	86.72	f	t
32	SKU032	Cookies Box	4	pcs	137.25	f	t
33	SKU033	Basmati Rice 1kg	5	pack	560.25	f	t
34	SKU034	Wheat Flour 5kg	5	pack	597.81	f	t
35	SKU035	Sugar 1kg	5	pack	562.63	f	t
36	SKU036	Salt 1kg	5	pack	506.90	f	t
37	SKU037	Toor Dal 1kg	5	pack	455.75	f	t
38	SKU038	Cooking Oil 1L	5	pack	154.01	f	t
39	SKU039	Tea Leaves 250g	5	pack	396.78	f	t
40	SKU040	Pasta 500g	5	pack	569.23	f	t
41	SKU041	Dish Soap 500ml	6	pcs	317.66	f	t
42	SKU042	Laundry Detergent 1kg	6	pcs	312.92	f	t
43	SKU043	Toilet Paper 4pk	6	pcs	87.40	f	t
44	SKU044	Hand Wash 250ml	6	pcs	304.75	f	t
45	SKU045	Tissue Box	6	pcs	101.34	f	t
46	SKU046	Garbage Bags	6	pcs	135.97	f	t
47	SKU047	Floor Cleaner 1L	6	pcs	42.24	f	t
48	SKU048	Sponge Pack	6	pcs	256.81	f	t
\.


--
-- Data for Name: purchase_orders; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.purchase_orders (po_id, supplier_id, status, created_by, created_at, approved_by, reason) FROM stdin;
\.


--
-- Data for Name: reorder_rules; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.reorder_rules (product_id, safety_stock, reorder_point, reorder_qty, auto_order) FROM stdin;
1	12	36	112	f
2	38	88	350	t
3	15	75	140	f
4	26	77	238	f
5	26	60	238	f
6	18	90	168	f
7	28	66	266	f
8	38	138	350	f
9	58	136	546	f
10	26	60	238	f
11	57	133	532	f
12	28	85	266	f
13	30	50	280	t
14	48	112	448	f
15	58	175	546	f
16	46	108	434	f
17	58	175	546	f
18	27	63	252	f
19	45	75	420	f
20	32	74	294	f
21	33	99	308	t
22	33	99	308	f
23	32	53	294	f
24	42	98	392	f
25	14	59	126	f
26	38	88	350	f
27	30	90	280	f
28	28	123	266	f
29	22	67	210	f
30	18	90	168	f
31	16	38	154	f
32	22	97	210	t
33	34	149	322	t
34	14	41	126	f
35	28	104	266	f
36	12	60	112	f
37	22	82	210	f
38	14	32	126	f
39	10	52	98	f
40	9	45	84	f
41	33	187	308	t
42	8	23	70	t
43	9	33	84	f
44	18	78	168	f
45	33	121	308	f
46	20	72	182	t
47	9	33	84	f
48	16	82	154	f
\.


--
-- Data for Name: stock_batches; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.stock_batches (batch_id, product_id, quantity, received_on, expiry_date) FROM stdin;
1	1	116	2026-07-25	\N
2	2	335	2026-07-25	\N
3	3	126	2026-07-25	\N
4	4	184	2026-07-25	\N
5	5	339	2026-07-25	\N
6	6	259	2026-07-25	\N
7	7	331	2026-07-25	\N
8	8	603	2026-07-25	\N
9	9	888	2026-07-25	2026-11-07
10	10	268	2026-07-25	2026-11-08
11	11	895	2026-07-25	2026-11-18
12	12	333	2026-07-25	2026-11-17
13	13	12	2026-07-25	2026-11-18
14	14	574	2026-07-25	2026-11-17
15	15	570	2026-07-25	2026-11-17
16	16	334	2026-07-25	2026-11-21
17	17	713	2026-07-25	2026-11-14
18	18	368	2026-07-25	2026-11-18
19	19	681	2026-07-25	2026-11-15
20	20	336	2026-07-25	2026-11-07
21	21	332	2026-07-25	2026-11-12
22	22	540	2026-07-25	2026-11-15
23	23	447	2026-07-25	2026-11-16
24	24	669	2026-07-25	2026-11-19
25	25	11	2026-07-25	\N
26	26	64	2026-07-25	\N
27	27	476	2026-07-25	\N
28	28	388	2026-07-25	\N
29	29	254	2026-07-25	\N
30	30	156	2026-07-25	\N
31	31	167	2026-07-25	\N
32	32	86	2026-07-25	\N
33	33	502	2026-07-25	\N
34	34	149	2026-07-25	\N
35	35	254	2026-07-25	\N
36	36	153	2026-07-25	\N
37	37	327	2026-07-25	\N
38	38	221	2026-07-25	\N
39	39	95	2026-07-25	\N
40	40	73	2026-07-25	\N
41	41	402	2026-07-25	\N
42	42	52	2026-07-25	\N
43	43	104	2026-07-25	\N
44	44	145	2026-07-25	\N
45	45	57	2026-07-25	\N
46	46	17	2026-07-25	\N
47	47	147	2026-07-25	\N
48	48	234	2026-07-25	\N
49	16	9	2026-10-20	2026-10-27
50	11	13	2026-10-20	2026-10-27
51	19	12	2026-10-20	2026-10-26
52	20	11	2026-10-20	2026-10-26
53	9	14	2026-10-20	2026-10-25
\.


--
-- Data for Name: suppliers; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.suppliers (supplier_id, name, phone, email) FROM stdin;
1	FreshFarm Distributors	9830011001	orders@freshfarm.example
2	Metro Wholesale	9830011002	sales@metrowholesale.example
3	Bengal Foods Pvt Ltd	9830011003	supply@bengalfoods.example
4	QuickStock Traders	9830011004	info@quickstock.example
5	Prime Household Supplies	9830011005	orders@primehousehold.example
\.


--
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.transactions (txn_id, product_id, batch_id, txn_type, quantity, txn_time, user_id) FROM stdin;
1	1	1	RECEIPT	930	2026-07-25 08:00:00	2
2	1	1	SALE	14	2026-07-25 14:11:00	3
3	1	1	SALE	8	2026-07-26 13:00:00	3
4	1	1	SALE	7	2026-07-27 20:34:00	3
5	1	1	SALE	6	2026-07-28 11:17:00	3
6	1	1	SALE	9	2026-07-29 09:03:00	3
7	1	1	SALE	9	2026-07-30 17:18:00	3
8	1	1	SALE	7	2026-07-31 20:08:00	3
9	1	1	SALE	11	2026-08-01 19:55:00	3
10	1	1	SALE	9	2026-08-02 16:06:00	3
11	1	1	SALE	10	2026-08-03 09:36:00	3
12	1	1	SALE	9	2026-08-04 13:30:00	3
13	1	1	SALE	7	2026-08-05 16:28:00	3
14	1	1	SALE	8	2026-08-06 14:11:00	3
15	1	1	SALE	11	2026-08-07 09:16:00	3
16	1	1	SALE	11	2026-08-08 16:07:00	3
17	1	1	SALE	11	2026-08-09 10:25:00	3
18	1	1	SALE	9	2026-08-10 16:04:00	3
19	1	1	SALE	9	2026-08-11 18:40:00	3
20	1	1	SALE	7	2026-08-12 19:03:00	3
21	1	1	SALE	9	2026-08-13 11:09:00	3
22	1	1	SALE	9	2026-08-14 18:19:00	3
23	1	1	SALE	32	2026-08-15 10:15:00	3
24	1	1	SALE	8	2026-08-16 10:35:00	3
25	1	1	SALE	9	2026-08-17 15:38:00	3
26	1	1	SALE	10	2026-08-18 18:50:00	3
27	1	1	SALE	6	2026-08-19 18:14:00	3
28	1	1	SALE	9	2026-08-20 17:24:00	3
29	1	1	SALE	5	2026-08-21 16:58:00	3
30	1	1	SALE	9	2026-08-22 16:19:00	3
31	1	1	SALE	13	2026-08-23 18:27:00	3
32	1	1	SALE	12	2026-08-24 13:36:00	3
33	1	1	SALE	6	2026-08-25 18:03:00	3
34	1	1	SALE	6	2026-08-26 18:47:00	3
35	1	1	SALE	7	2026-08-27 10:48:00	3
36	1	1	SALE	9	2026-08-28 12:40:00	3
37	1	1	SALE	10	2026-08-29 12:16:00	3
38	1	1	SALE	12	2026-08-30 19:05:00	3
39	1	1	SALE	7	2026-08-31 11:15:00	3
40	1	1	SALE	9	2026-09-01 11:35:00	3
41	1	1	SALE	6	2026-09-02 10:10:00	3
42	1	1	SALE	9	2026-09-03 09:26:00	3
43	1	1	SALE	8	2026-09-04 16:44:00	3
44	1	1	SALE	12	2026-09-05 18:30:00	3
45	1	1	SALE	12	2026-09-06 13:02:00	3
46	1	1	SALE	7	2026-09-07 12:18:00	3
47	1	1	SALE	8	2026-09-08 20:18:00	3
48	1	1	SALE	8	2026-09-09 20:55:00	3
49	1	1	SALE	10	2026-09-10 16:04:00	3
50	1	1	SALE	7	2026-09-11 19:14:00	3
51	1	1	SALE	8	2026-09-12 13:50:00	3
52	1	1	SALE	9	2026-09-13 19:37:00	3
53	1	1	SALE	6	2026-09-14 19:51:00	3
54	1	1	SALE	9	2026-09-15 12:27:00	3
55	1	1	SALE	10	2026-09-16 10:34:00	3
56	1	1	SALE	8	2026-09-17 12:41:00	3
57	1	1	SALE	7	2026-09-18 11:58:00	3
58	1	1	SALE	11	2026-09-19 13:52:00	3
59	1	1	SALE	11	2026-09-20 11:04:00	3
60	1	1	SALE	8	2026-09-21 09:10:00	3
61	1	1	SALE	8	2026-09-22 13:38:00	3
62	1	1	SALE	7	2026-09-23 20:52:00	3
63	1	1	SALE	9	2026-09-24 18:58:00	3
64	1	1	SALE	9	2026-09-25 13:28:00	3
65	1	1	SALE	12	2026-09-26 10:29:00	3
66	1	1	SALE	12	2026-09-27 20:19:00	3
67	1	1	SALE	6	2026-09-28 20:25:00	3
68	1	1	SALE	7	2026-09-29 13:32:00	3
69	1	1	SALE	9	2026-09-30 17:31:00	3
70	1	1	SALE	5	2026-10-01 16:05:00	3
71	1	1	SALE	9	2026-10-02 18:02:00	3
72	1	1	SALE	10	2026-10-03 15:47:00	3
73	1	1	SALE	11	2026-10-04 14:38:00	3
74	1	1	SALE	8	2026-10-05 13:01:00	3
75	1	1	SALE	10	2026-10-06 10:14:00	3
76	1	1	SALE	7	2026-10-07 19:53:00	3
77	1	1	SALE	8	2026-10-08 18:37:00	3
78	1	1	SALE	7	2026-10-09 09:48:00	3
79	1	1	SALE	11	2026-10-10 19:52:00	3
80	1	1	SALE	10	2026-10-11 13:36:00	3
81	1	1	SALE	10	2026-10-12 09:48:00	3
82	1	1	SALE	7	2026-10-13 11:30:00	3
83	1	1	SALE	9	2026-10-14 17:41:00	3
84	1	1	SALE	7	2026-10-15 16:58:00	3
85	1	1	SALE	8	2026-10-16 13:11:00	3
86	1	1	SALE	11	2026-10-17 18:27:00	3
87	1	1	SALE	11	2026-10-18 19:52:00	3
88	1	1	SALE	9	2026-10-19 16:05:00	3
89	1	1	SALE	10	2026-10-20 16:22:00	3
90	1	1	SALE	8	2026-10-21 15:21:00	3
91	1	1	SALE	6	2026-10-22 14:42:00	3
92	2	2	RECEIPT	3045	2026-07-25 08:00:00	2
93	2	2	SALE	36	2026-07-25 19:46:00	3
94	2	2	SALE	40	2026-07-26 19:25:00	3
95	2	2	SALE	25	2026-07-27 17:23:00	3
96	2	2	SALE	24	2026-07-28 10:50:00	3
97	2	2	SALE	31	2026-07-29 15:00:00	3
98	2	2	SALE	31	2026-07-30 13:34:00	3
99	2	2	SALE	35	2026-07-31 10:29:00	3
100	2	2	SALE	33	2026-08-01 14:43:00	3
101	2	2	SALE	30	2026-08-02 20:43:00	3
102	2	2	SALE	25	2026-08-03 13:37:00	3
103	2	2	SALE	28	2026-08-04 15:52:00	3
104	2	2	SALE	28	2026-08-05 19:23:00	3
105	2	2	SALE	32	2026-08-06 10:43:00	3
106	2	2	SALE	26	2026-08-07 12:30:00	3
107	2	2	SALE	39	2026-08-08 09:39:00	3
108	2	2	SALE	37	2026-08-09 17:20:00	3
109	2	2	SALE	32	2026-08-10 18:14:00	3
110	2	2	SALE	23	2026-08-11 19:04:00	3
111	2	2	SALE	23	2026-08-12 19:52:00	3
112	2	2	SALE	33	2026-08-13 16:58:00	3
113	2	2	SALE	20	2026-08-14 20:19:00	3
114	2	2	SALE	34	2026-08-15 19:26:00	3
115	2	2	SALE	37	2026-08-16 10:08:00	3
116	2	2	SALE	26	2026-08-17 09:02:00	3
117	2	2	SALE	20	2026-08-18 13:31:00	3
118	2	2	SALE	87	2026-08-19 10:06:00	3
119	2	2	SALE	28	2026-08-20 12:56:00	3
120	2	2	SALE	19	2026-08-21 17:08:00	3
121	2	2	SALE	30	2026-08-22 15:29:00	3
122	2	2	SALE	35	2026-08-23 14:42:00	3
123	2	2	SALE	35	2026-08-24 20:44:00	3
124	2	2	SALE	15	2026-08-25 17:26:00	3
125	2	2	SALE	28	2026-08-26 18:47:00	3
126	2	2	SALE	21	2026-08-27 20:09:00	3
127	2	2	SALE	29	2026-08-28 15:41:00	3
128	2	2	SALE	34	2026-08-29 10:53:00	3
129	2	2	SALE	36	2026-08-30 16:39:00	3
130	2	2	SALE	24	2026-08-31 15:17:00	3
131	2	2	SALE	33	2026-09-01 09:44:00	3
132	2	2	SALE	31	2026-09-02 14:13:00	3
133	2	2	SALE	28	2026-09-03 16:28:00	3
134	2	2	SALE	25	2026-09-04 12:54:00	3
135	2	2	SALE	34	2026-09-05 14:06:00	3
136	2	2	SALE	31	2026-09-06 19:23:00	3
137	2	2	SALE	21	2026-09-07 17:57:00	3
138	2	2	SALE	32	2026-09-08 19:22:00	3
139	2	2	SALE	18	2026-09-09 09:25:00	3
140	2	2	SALE	18	2026-09-10 13:12:00	3
141	2	2	SALE	22	2026-09-11 10:54:00	3
142	2	2	SALE	31	2026-09-12 16:05:00	3
143	2	2	SALE	41	2026-09-13 19:13:00	3
144	2	2	SALE	24	2026-09-14 19:40:00	3
145	2	2	SALE	27	2026-09-15 18:01:00	3
146	2	2	SALE	29	2026-09-16 09:50:00	3
147	2	2	SALE	29	2026-09-17 14:15:00	3
148	2	2	SALE	27	2026-09-18 11:50:00	3
149	2	2	SALE	33	2026-09-19 18:13:00	3
150	2	2	SALE	33	2026-09-20 10:53:00	3
151	2	2	SALE	23	2026-09-21 17:13:00	3
152	2	2	SALE	20	2026-09-22 18:13:00	3
153	2	2	SALE	21	2026-09-23 12:21:00	3
154	2	2	SALE	21	2026-09-24 11:50:00	3
155	2	2	SALE	21	2026-09-25 18:00:00	3
156	2	2	SALE	34	2026-09-26 13:54:00	3
157	2	2	SALE	34	2026-09-27 11:08:00	3
158	2	2	SALE	37	2026-09-28 17:16:00	3
159	2	2	SALE	19	2026-09-29 11:07:00	3
160	2	2	SALE	43	2026-09-30 19:55:00	3
161	2	2	SALE	22	2026-10-01 09:08:00	3
162	2	2	SALE	28	2026-10-02 09:22:00	3
163	2	2	SALE	100	2026-10-03 12:37:00	3
164	2	2	SALE	32	2026-10-04 14:01:00	3
165	2	2	SALE	32	2026-10-05 11:16:00	3
166	2	2	SALE	21	2026-10-06 09:08:00	3
167	2	2	SALE	26	2026-10-07 20:26:00	3
168	2	2	SALE	21	2026-10-08 17:07:00	3
169	2	2	SALE	26	2026-10-09 20:04:00	3
170	2	2	SALE	40	2026-10-10 16:28:00	3
171	2	2	SALE	39	2026-10-11 14:32:00	3
172	2	2	SALE	29	2026-10-12 18:06:00	3
173	2	2	SALE	30	2026-10-13 16:32:00	3
174	2	2	SALE	26	2026-10-14 12:39:00	3
175	2	2	SALE	23	2026-10-15 09:46:00	3
176	2	2	SALE	30	2026-10-16 19:33:00	3
177	2	2	SALE	33	2026-10-17 13:29:00	3
178	2	2	SALE	38	2026-10-18 19:01:00	3
179	2	2	SALE	37	2026-10-19 09:30:00	3
180	2	2	SALE	21	2026-10-20 15:27:00	3
181	2	2	SALE	27	2026-10-21 19:06:00	3
182	2	2	SALE	20	2026-10-22 16:45:00	3
183	3	3	RECEIPT	1108	2026-07-25 08:00:00	2
184	3	3	SALE	16	2026-07-25 12:45:00	3
185	3	3	SALE	13	2026-07-26 16:28:00	3
186	3	3	SALE	8	2026-07-27 17:33:00	3
187	3	3	SALE	8	2026-07-28 18:10:00	3
188	3	3	SALE	8	2026-07-29 14:23:00	3
189	3	3	SALE	10	2026-07-30 13:24:00	3
190	3	3	SALE	9	2026-07-31 15:49:00	3
191	3	3	SALE	11	2026-08-01 14:43:00	3
192	3	3	SALE	12	2026-08-02 18:03:00	3
193	3	3	SALE	10	2026-08-03 19:41:00	3
194	3	3	SALE	9	2026-08-04 14:04:00	3
195	3	3	SALE	10	2026-08-05 14:06:00	3
196	3	3	SALE	9	2026-08-06 17:43:00	3
197	3	3	SALE	11	2026-08-07 15:18:00	3
198	3	3	SALE	15	2026-08-08 13:46:00	3
199	3	3	SALE	15	2026-08-09 19:58:00	3
200	3	3	SALE	8	2026-08-10 18:55:00	3
201	3	3	SALE	9	2026-08-11 11:21:00	3
202	3	3	SALE	8	2026-08-12 10:37:00	3
203	3	3	SALE	12	2026-08-13 19:09:00	3
204	3	3	SALE	9	2026-08-14 14:19:00	3
205	3	3	SALE	9	2026-08-15 19:44:00	3
206	3	3	SALE	13	2026-08-16 19:25:00	3
207	3	3	SALE	9	2026-08-17 11:38:00	3
208	3	3	SALE	8	2026-08-18 20:05:00	3
209	3	3	SALE	13	2026-08-19 13:35:00	3
210	3	3	SALE	13	2026-08-20 15:41:00	3
211	3	3	SALE	6	2026-08-21 14:52:00	3
212	3	3	SALE	19	2026-08-22 11:42:00	3
213	3	3	SALE	14	2026-08-23 20:53:00	3
214	3	3	SALE	9	2026-08-24 20:43:00	3
215	3	3	SALE	23	2026-08-25 17:05:00	3
216	3	3	SALE	8	2026-08-26 19:42:00	3
217	3	3	SALE	9	2026-08-27 15:32:00	3
218	3	3	SALE	13	2026-08-28 14:01:00	3
219	3	3	SALE	14	2026-08-29 14:19:00	3
220	3	3	SALE	13	2026-08-30 11:13:00	3
221	3	3	SALE	7	2026-08-31 14:49:00	3
222	3	3	SALE	11	2026-09-01 16:12:00	3
223	3	3	SALE	10	2026-09-02 12:08:00	3
224	3	3	SALE	10	2026-09-03 11:04:00	3
225	3	3	SALE	13	2026-09-04 13:54:00	3
226	3	3	SALE	14	2026-09-05 10:32:00	3
227	3	3	SALE	13	2026-09-06 17:53:00	3
228	3	3	SALE	7	2026-09-07 20:56:00	3
229	3	3	SALE	10	2026-09-08 17:02:00	3
230	3	3	SALE	10	2026-09-09 19:21:00	3
231	3	3	SALE	10	2026-09-10 18:08:00	3
232	3	3	SALE	11	2026-09-11 18:24:00	3
233	3	3	SALE	14	2026-09-12 11:10:00	3
234	3	3	SALE	11	2026-09-13 11:53:00	3
235	3	3	SALE	12	2026-09-14 20:49:00	3
236	3	3	SALE	10	2026-09-15 18:51:00	3
237	3	3	SALE	9	2026-09-16 11:46:00	3
238	3	3	SALE	14	2026-09-17 16:02:00	3
239	3	3	SALE	11	2026-09-18 15:23:00	3
240	3	3	SALE	14	2026-09-19 19:46:00	3
241	3	3	SALE	11	2026-09-20 12:28:00	3
242	3	3	SALE	11	2026-09-21 18:18:00	3
243	3	3	SALE	7	2026-09-22 20:50:00	3
244	3	3	SALE	13	2026-09-23 16:14:00	3
245	3	3	SALE	12	2026-09-24 17:15:00	3
246	3	3	SALE	8	2026-09-25 13:51:00	3
247	3	3	SALE	13	2026-09-26 16:57:00	3
248	3	3	SALE	12	2026-09-27 12:23:00	3
249	3	3	SALE	10	2026-09-28 19:36:00	3
250	3	3	SALE	8	2026-09-29 16:29:00	3
251	3	3	SALE	13	2026-09-30 13:49:00	3
252	3	3	SALE	10	2026-10-01 15:32:00	3
253	3	3	SALE	11	2026-10-02 17:26:00	3
254	3	3	SALE	14	2026-10-03 11:52:00	3
255	3	3	SALE	13	2026-10-04 12:51:00	3
256	3	3	SALE	10	2026-10-05 18:08:00	3
257	3	3	SALE	8	2026-10-06 13:03:00	3
258	3	3	SALE	8	2026-10-07 19:30:00	3
259	3	3	SALE	8	2026-10-08 14:35:00	3
260	3	3	SALE	10	2026-10-09 10:45:00	3
261	3	3	SALE	14	2026-10-10 17:54:00	3
262	3	3	SALE	11	2026-10-11 10:18:00	3
263	3	3	SALE	10	2026-10-12 10:48:00	3
264	3	3	SALE	10	2026-10-13 11:17:00	3
265	3	3	SALE	9	2026-10-14 16:57:00	3
266	3	3	SALE	8	2026-10-15 17:09:00	3
267	3	3	SALE	8	2026-10-16 15:05:00	3
268	3	3	SALE	16	2026-10-17 12:52:00	3
269	3	3	SALE	13	2026-10-18 16:56:00	3
270	3	3	SALE	9	2026-10-19 14:59:00	3
271	3	3	SALE	10	2026-10-20 09:26:00	3
272	3	3	SALE	11	2026-10-21 09:25:00	3
273	3	3	SALE	9	2026-10-22 17:23:00	3
274	4	4	RECEIPT	1882	2026-07-25 08:00:00	2
275	4	4	SALE	26	2026-07-25 10:33:00	3
276	4	4	SALE	25	2026-07-26 11:19:00	3
277	4	4	SALE	13	2026-07-27 11:10:00	3
278	4	4	SALE	12	2026-07-28 14:59:00	3
279	4	4	SALE	20	2026-07-29 20:14:00	3
280	4	4	SALE	12	2026-07-30 14:33:00	3
281	4	4	SALE	17	2026-07-31 13:54:00	3
282	4	4	SALE	23	2026-08-01 10:16:00	3
283	4	4	SALE	23	2026-08-02 12:40:00	3
284	4	4	SALE	13	2026-08-03 17:17:00	3
285	4	4	SALE	17	2026-08-04 11:40:00	3
286	4	4	SALE	18	2026-08-05 13:39:00	3
287	4	4	SALE	15	2026-08-06 17:05:00	3
288	4	4	SALE	17	2026-08-07 17:41:00	3
289	4	4	SALE	20	2026-08-08 11:37:00	3
290	4	4	SALE	23	2026-08-09 18:09:00	3
291	4	4	SALE	17	2026-08-10 11:42:00	3
292	4	4	SALE	21	2026-08-11 18:46:00	3
293	4	4	SALE	18	2026-08-12 18:21:00	3
294	4	4	SALE	17	2026-08-13 18:02:00	3
295	4	4	SALE	21	2026-08-14 09:05:00	3
296	4	4	SALE	23	2026-08-15 09:41:00	3
297	4	4	SALE	25	2026-08-16 18:16:00	3
298	4	4	SALE	18	2026-08-17 19:13:00	3
299	4	4	SALE	16	2026-08-18 18:26:00	3
300	4	4	SALE	12	2026-08-19 18:40:00	3
301	4	4	SALE	16	2026-08-20 09:31:00	3
302	4	4	SALE	18	2026-08-21 19:34:00	3
303	4	4	SALE	23	2026-08-22 13:41:00	3
304	4	4	SALE	21	2026-08-23 13:30:00	3
305	4	4	SALE	22	2026-08-24 12:51:00	3
306	4	4	SALE	19	2026-08-25 19:25:00	3
307	4	4	SALE	19	2026-08-26 13:29:00	3
308	4	4	SALE	18	2026-08-27 10:44:00	3
309	4	4	SALE	7	2026-08-28 09:10:00	3
310	4	4	SALE	22	2026-08-29 16:26:00	3
311	4	4	SALE	19	2026-08-30 16:29:00	3
312	4	4	SALE	22	2026-08-31 12:21:00	3
313	4	4	SALE	19	2026-09-01 18:09:00	3
314	4	4	SALE	19	2026-09-02 14:55:00	3
315	4	4	SALE	20	2026-09-03 20:20:00	3
316	4	4	SALE	15	2026-09-04 20:55:00	3
317	4	4	SALE	27	2026-09-05 14:25:00	3
318	4	4	SALE	23	2026-09-06 11:48:00	3
319	4	4	SALE	12	2026-09-07 14:32:00	3
320	4	4	SALE	13	2026-09-08 17:06:00	3
321	4	4	SALE	21	2026-09-09 14:15:00	3
322	4	4	SALE	19	2026-09-10 16:07:00	3
323	4	4	SALE	12	2026-09-11 13:28:00	3
324	4	4	SALE	25	2026-09-12 12:09:00	3
325	4	4	SALE	26	2026-09-13 10:03:00	3
326	4	4	SALE	17	2026-09-14 13:24:00	3
327	4	4	SALE	21	2026-09-15 18:26:00	3
328	4	4	SALE	19	2026-09-16 12:55:00	3
329	4	4	SALE	13	2026-09-17 11:52:00	3
330	4	4	SALE	9	2026-09-18 14:59:00	3
331	4	4	SALE	26	2026-09-19 18:46:00	3
332	4	4	SALE	24	2026-09-20 14:12:00	3
333	4	4	SALE	13	2026-09-21 11:31:00	3
334	4	4	SALE	15	2026-09-22 17:29:00	3
335	4	4	SALE	13	2026-09-23 16:56:00	3
336	4	4	SALE	21	2026-09-24 13:31:00	3
337	4	4	SALE	13	2026-09-25 09:05:00	3
338	4	4	SALE	25	2026-09-26 15:32:00	3
339	4	4	SALE	20	2026-09-27 16:15:00	3
340	4	4	SALE	20	2026-09-28 12:37:00	3
341	4	4	SALE	6	2026-09-29 14:03:00	3
342	4	4	SALE	21	2026-09-30 09:18:00	3
343	4	4	SALE	15	2026-10-01 16:38:00	3
344	4	4	SALE	17	2026-10-02 19:43:00	3
345	4	4	SALE	24	2026-10-03 16:18:00	3
346	4	4	SALE	25	2026-10-04 17:00:00	3
347	4	4	SALE	16	2026-10-05 10:27:00	3
348	4	4	SALE	18	2026-10-06 11:56:00	3
349	4	4	SALE	20	2026-10-07 13:46:00	3
350	4	4	SALE	13	2026-10-08 14:48:00	3
351	4	4	SALE	18	2026-10-09 15:23:00	3
352	4	4	SALE	19	2026-10-10 09:25:00	3
353	4	4	SALE	29	2026-10-11 09:36:00	3
354	4	4	SALE	18	2026-10-12 17:12:00	3
355	4	4	SALE	13	2026-10-13 14:35:00	3
356	4	4	SALE	16	2026-10-14 13:04:00	3
357	4	4	SALE	22	2026-10-15 15:32:00	3
358	4	4	SALE	17	2026-10-16 16:48:00	3
359	4	4	SALE	33	2026-10-17 17:17:00	3
360	4	4	SALE	28	2026-10-18 18:43:00	3
361	4	4	SALE	13	2026-10-19 18:07:00	3
362	4	4	SALE	23	2026-10-20 11:06:00	3
363	4	4	SALE	21	2026-10-21 15:23:00	3
364	4	4	SALE	25	2026-10-22 14:35:00	3
365	5	5	RECEIPT	2125	2026-07-25 08:00:00	2
366	5	5	SALE	25	2026-07-25 12:48:00	3
367	5	5	SALE	22	2026-07-26 12:43:00	3
368	5	5	SALE	19	2026-07-27 18:55:00	3
369	5	5	SALE	19	2026-07-28 10:33:00	3
370	5	5	SALE	14	2026-07-29 16:33:00	3
371	5	5	SALE	14	2026-07-30 20:23:00	3
372	5	5	SALE	22	2026-07-31 10:58:00	3
373	5	5	SALE	32	2026-08-01 18:07:00	3
374	5	5	SALE	20	2026-08-02 09:53:00	3
375	5	5	SALE	16	2026-08-03 17:57:00	3
376	5	5	SALE	14	2026-08-04 17:12:00	3
377	5	5	SALE	21	2026-08-05 18:34:00	3
378	5	5	SALE	19	2026-08-06 11:10:00	3
379	5	5	SALE	12	2026-08-07 14:54:00	3
380	5	5	SALE	30	2026-08-08 17:28:00	3
381	5	5	SALE	23	2026-08-09 10:43:00	3
382	5	5	SALE	15	2026-08-10 12:45:00	3
383	5	5	SALE	16	2026-08-11 18:31:00	3
384	5	5	SALE	18	2026-08-12 10:57:00	3
385	5	5	SALE	15	2026-08-13 17:28:00	3
386	5	5	SALE	44	2026-08-14 09:29:00	3
387	5	5	SALE	22	2026-08-15 11:32:00	3
388	5	5	SALE	25	2026-08-16 15:29:00	3
389	5	5	SALE	9	2026-08-17 18:03:00	3
390	5	5	SALE	19	2026-08-18 17:29:00	3
391	5	5	SALE	18	2026-08-19 19:51:00	3
392	5	5	SALE	15	2026-08-20 13:46:00	3
393	5	5	SALE	13	2026-08-21 09:25:00	3
394	5	5	SALE	23	2026-08-22 13:52:00	3
395	5	5	SALE	27	2026-08-23 09:47:00	3
396	5	5	SALE	15	2026-08-24 12:37:00	3
397	5	5	SALE	13	2026-08-25 10:02:00	3
398	5	5	SALE	15	2026-08-26 15:22:00	3
399	5	5	SALE	16	2026-08-27 20:04:00	3
400	5	5	SALE	16	2026-08-28 17:03:00	3
401	5	5	SALE	25	2026-08-29 10:59:00	3
402	5	5	SALE	26	2026-08-30 16:02:00	3
403	5	5	SALE	14	2026-08-31 13:26:00	3
404	5	5	SALE	10	2026-09-01 11:49:00	3
405	5	5	SALE	24	2026-09-02 11:49:00	3
406	5	5	SALE	18	2026-09-03 19:46:00	3
407	5	5	SALE	14	2026-09-04 19:26:00	3
408	5	5	SALE	21	2026-09-05 14:57:00	3
409	5	5	SALE	24	2026-09-06 15:28:00	3
410	5	5	SALE	22	2026-09-07 15:24:00	3
411	5	5	SALE	15	2026-09-08 10:43:00	3
412	5	5	SALE	15	2026-09-09 19:55:00	3
413	5	5	SALE	16	2026-09-10 17:08:00	3
414	5	5	SALE	16	2026-09-11 19:55:00	3
415	5	5	SALE	24	2026-09-12 14:07:00	3
416	5	5	SALE	29	2026-09-13 11:34:00	3
417	5	5	SALE	17	2026-09-14 15:33:00	3
418	5	5	SALE	23	2026-09-15 11:46:00	3
419	5	5	SALE	14	2026-09-16 12:53:00	3
420	5	5	SALE	20	2026-09-17 09:48:00	3
421	5	5	SALE	16	2026-09-18 09:19:00	3
422	5	5	SALE	19	2026-09-19 16:43:00	3
423	5	5	SALE	23	2026-09-20 20:34:00	3
424	5	5	SALE	20	2026-09-21 15:34:00	3
425	5	5	SALE	23	2026-09-22 15:52:00	3
426	5	5	SALE	20	2026-09-23 12:15:00	3
427	5	5	SALE	17	2026-09-24 16:22:00	3
428	5	5	SALE	25	2026-09-25 11:17:00	3
429	5	5	SALE	20	2026-09-26 12:59:00	3
430	5	5	SALE	25	2026-09-27 20:48:00	3
431	5	5	SALE	17	2026-09-28 10:02:00	3
432	5	5	SALE	9	2026-09-29 19:26:00	3
433	5	5	SALE	17	2026-09-30 18:49:00	3
434	5	5	SALE	18	2026-10-01 09:15:00	3
435	5	5	SALE	19	2026-10-02 12:04:00	3
436	5	5	SALE	25	2026-10-03 10:38:00	3
437	5	5	SALE	29	2026-10-04 09:28:00	3
438	5	5	SALE	20	2026-10-05 18:43:00	3
439	5	5	SALE	23	2026-10-06 20:55:00	3
440	5	5	SALE	16	2026-10-07 09:15:00	3
441	5	5	SALE	17	2026-10-08 20:02:00	3
442	5	5	SALE	19	2026-10-09 15:28:00	3
443	5	5	SALE	25	2026-10-10 12:34:00	3
444	5	5	SALE	27	2026-10-11 12:48:00	3
445	5	5	SALE	42	2026-10-12 09:08:00	3
446	5	5	SALE	17	2026-10-13 17:18:00	3
447	5	5	SALE	16	2026-10-14 12:52:00	3
448	5	5	SALE	14	2026-10-15 20:36:00	3
449	5	5	SALE	19	2026-10-16 14:36:00	3
450	5	5	SALE	29	2026-10-17 18:49:00	3
451	5	5	SALE	29	2026-10-18 19:52:00	3
452	5	5	SALE	18	2026-10-19 14:15:00	3
453	5	5	SALE	18	2026-10-20 13:56:00	3
454	5	5	SALE	13	2026-10-21 11:42:00	3
455	5	5	SALE	19	2026-10-22 17:14:00	3
456	6	6	RECEIPT	1455	2026-07-25 08:00:00	2
457	6	6	SALE	16	2026-07-25 13:51:00	3
458	6	6	SALE	20	2026-07-26 12:45:00	3
459	6	6	SALE	11	2026-07-27 10:05:00	3
460	6	6	SALE	9	2026-07-28 13:09:00	3
461	6	6	SALE	11	2026-07-29 15:45:00	3
462	6	6	SALE	10	2026-07-30 19:09:00	3
463	6	6	SALE	10	2026-07-31 20:24:00	3
464	6	6	SALE	18	2026-08-01 14:23:00	3
465	6	6	SALE	17	2026-08-02 10:05:00	3
466	6	6	SALE	11	2026-08-03 09:19:00	3
467	6	6	SALE	10	2026-08-04 16:23:00	3
468	6	6	SALE	13	2026-08-05 13:06:00	3
469	6	6	SALE	12	2026-08-06 11:05:00	3
470	6	6	SALE	14	2026-08-07 11:27:00	3
471	6	6	SALE	12	2026-08-08 16:35:00	3
472	6	6	SALE	16	2026-08-09 17:32:00	3
473	6	6	SALE	13	2026-08-10 15:06:00	3
474	6	6	SALE	12	2026-08-11 09:05:00	3
475	6	6	SALE	11	2026-08-12 14:35:00	3
476	6	6	SALE	11	2026-08-13 10:38:00	3
477	6	6	SALE	10	2026-08-14 18:50:00	3
478	6	6	SALE	21	2026-08-15 14:55:00	3
479	6	6	SALE	18	2026-08-16 15:00:00	3
480	6	6	SALE	7	2026-08-17 13:26:00	3
481	6	6	SALE	11	2026-08-18 15:49:00	3
482	6	6	SALE	13	2026-08-19 10:46:00	3
483	6	6	SALE	9	2026-08-20 17:57:00	3
484	6	6	SALE	13	2026-08-21 12:36:00	3
485	6	6	SALE	13	2026-08-22 17:10:00	3
486	6	6	SALE	18	2026-08-23 19:24:00	3
487	6	6	SALE	13	2026-08-24 11:08:00	3
488	6	6	SALE	14	2026-08-25 13:19:00	3
489	6	6	SALE	12	2026-08-26 13:31:00	3
490	6	6	SALE	12	2026-08-27 11:04:00	3
491	6	6	SALE	12	2026-08-28 11:27:00	3
492	6	6	SALE	14	2026-08-29 13:26:00	3
493	6	6	SALE	11	2026-08-30 13:30:00	3
494	6	6	SALE	10	2026-08-31 10:23:00	3
495	6	6	SALE	8	2026-09-01 13:15:00	3
496	6	6	SALE	12	2026-09-02 20:40:00	3
497	6	6	SALE	12	2026-09-03 16:38:00	3
498	6	6	SALE	10	2026-09-04 18:12:00	3
499	6	6	SALE	22	2026-09-05 16:06:00	3
500	6	6	SALE	12	2026-09-06 11:19:00	3
501	6	6	SALE	16	2026-09-07 09:25:00	3
502	6	6	SALE	30	2026-09-08 14:53:00	3
503	6	6	SALE	11	2026-09-09 18:24:00	3
504	6	6	SALE	11	2026-09-10 14:28:00	3
505	6	6	SALE	11	2026-09-11 14:27:00	3
506	6	6	SALE	18	2026-09-12 19:38:00	3
507	6	6	SALE	20	2026-09-13 11:19:00	3
508	6	6	SALE	33	2026-09-14 14:38:00	3
509	6	6	SALE	10	2026-09-15 20:12:00	3
510	6	6	SALE	12	2026-09-16 16:20:00	3
511	6	6	SALE	7	2026-09-17 11:25:00	3
512	6	6	SALE	14	2026-09-18 14:18:00	3
513	6	6	SALE	17	2026-09-19 20:44:00	3
514	6	6	SALE	20	2026-09-20 19:31:00	3
515	6	6	SALE	17	2026-09-21 18:50:00	3
516	6	6	SALE	15	2026-09-22 12:20:00	3
517	6	6	SALE	11	2026-09-23 15:17:00	3
518	6	6	SALE	10	2026-09-24 15:23:00	3
519	6	6	SALE	15	2026-09-25 10:59:00	3
520	6	6	SALE	16	2026-09-26 18:12:00	3
521	6	6	SALE	14	2026-09-27 18:34:00	3
522	6	6	SALE	9	2026-09-28 11:43:00	3
523	6	6	SALE	11	2026-09-29 17:01:00	3
524	6	6	SALE	10	2026-09-30 20:29:00	3
525	6	6	SALE	16	2026-10-01 20:13:00	3
526	6	6	SALE	9	2026-10-02 16:51:00	3
527	6	6	SALE	16	2026-10-03 13:53:00	3
528	6	6	SALE	16	2026-10-04 20:04:00	3
529	6	6	SALE	9	2026-10-05 15:43:00	3
530	6	6	SALE	11	2026-10-06 16:08:00	3
531	6	6	SALE	14	2026-10-07 19:19:00	3
532	6	6	SALE	12	2026-10-08 12:16:00	3
533	6	6	SALE	14	2026-10-09 19:09:00	3
534	6	6	SALE	12	2026-10-10 20:27:00	3
535	6	6	SALE	16	2026-10-11 15:04:00	3
536	6	6	SALE	9	2026-10-12 16:38:00	3
537	6	6	SALE	13	2026-10-13 16:37:00	3
538	6	6	SALE	8	2026-10-14 15:34:00	3
539	6	6	SALE	11	2026-10-15 17:59:00	3
540	6	6	SALE	13	2026-10-16 20:26:00	3
541	6	6	SALE	15	2026-10-17 17:02:00	3
542	6	6	SALE	14	2026-10-18 14:44:00	3
543	6	6	SALE	13	2026-10-19 17:38:00	3
544	6	6	SALE	9	2026-10-20 19:58:00	3
545	6	6	SALE	11	2026-10-21 10:06:00	3
546	6	6	SALE	13	2026-10-22 12:42:00	3
547	7	7	RECEIPT	2291	2026-07-25 08:00:00	2
548	7	7	SALE	30	2026-07-25 14:53:00	3
549	7	7	SALE	32	2026-07-26 13:21:00	3
550	7	7	SALE	22	2026-07-27 17:36:00	3
551	7	7	SALE	18	2026-07-28 11:36:00	3
552	7	7	SALE	21	2026-07-29 16:50:00	3
553	7	7	SALE	21	2026-07-30 14:57:00	3
554	7	7	SALE	18	2026-07-31 19:48:00	3
555	7	7	SALE	24	2026-08-01 09:02:00	3
556	7	7	SALE	35	2026-08-02 10:40:00	3
557	7	7	SALE	30	2026-08-03 16:01:00	3
558	7	7	SALE	20	2026-08-04 10:59:00	3
559	7	7	SALE	18	2026-08-05 11:28:00	3
560	7	7	SALE	17	2026-08-06 16:00:00	3
561	7	7	SALE	22	2026-08-07 15:12:00	3
562	7	7	SALE	31	2026-08-08 20:58:00	3
563	7	7	SALE	28	2026-08-09 11:56:00	3
564	7	7	SALE	19	2026-08-10 19:19:00	3
565	7	7	SALE	18	2026-08-11 11:55:00	3
566	7	7	SALE	22	2026-08-12 13:05:00	3
567	7	7	SALE	11	2026-08-13 19:23:00	3
568	7	7	SALE	16	2026-08-14 13:05:00	3
569	7	7	SALE	25	2026-08-15 14:42:00	3
570	7	7	SALE	29	2026-08-16 19:10:00	3
571	7	7	SALE	24	2026-08-17 09:25:00	3
572	7	7	SALE	22	2026-08-18 19:19:00	3
573	7	7	SALE	35	2026-08-19 20:44:00	3
574	7	7	SALE	18	2026-08-20 12:27:00	3
575	7	7	SALE	25	2026-08-21 19:05:00	3
576	7	7	SALE	24	2026-08-22 20:06:00	3
577	7	7	SALE	24	2026-08-23 09:13:00	3
578	7	7	SALE	9	2026-08-24 16:04:00	3
579	7	7	SALE	20	2026-08-25 11:37:00	3
580	7	7	SALE	18	2026-08-26 12:33:00	3
581	7	7	SALE	20	2026-08-27 19:28:00	3
582	7	7	SALE	22	2026-08-28 09:00:00	3
583	7	7	SALE	33	2026-08-29 20:21:00	3
584	7	7	SALE	26	2026-08-30 10:55:00	3
585	7	7	SALE	22	2026-08-31 15:44:00	3
586	7	7	SALE	21	2026-09-01 11:30:00	3
587	7	7	SALE	22	2026-09-02 10:14:00	3
588	7	7	SALE	15	2026-09-03 15:05:00	3
589	7	7	SALE	21	2026-09-04 20:51:00	3
590	7	7	SALE	29	2026-09-05 10:06:00	3
591	7	7	SALE	27	2026-09-06 14:23:00	3
592	7	7	SALE	13	2026-09-07 13:08:00	3
593	7	7	SALE	14	2026-09-08 15:49:00	3
594	7	7	SALE	20	2026-09-09 11:41:00	3
595	7	7	SALE	23	2026-09-10 19:09:00	3
596	7	7	SALE	15	2026-09-11 10:33:00	3
597	7	7	SALE	29	2026-09-12 18:00:00	3
598	7	7	SALE	28	2026-09-13 18:41:00	3
599	7	7	SALE	16	2026-09-14 11:28:00	3
600	7	7	SALE	17	2026-09-15 14:46:00	3
601	7	7	SALE	25	2026-09-16 12:40:00	3
602	7	7	SALE	14	2026-09-17 20:09:00	3
603	7	7	SALE	19	2026-09-18 15:39:00	3
604	7	7	SALE	32	2026-09-19 19:28:00	3
605	7	7	SALE	27	2026-09-20 12:05:00	3
606	7	7	SALE	20	2026-09-21 10:08:00	3
607	7	7	SALE	23	2026-09-22 10:37:00	3
608	7	7	SALE	19	2026-09-23 20:24:00	3
609	7	7	SALE	27	2026-09-24 14:27:00	3
610	7	7	SALE	20	2026-09-25 14:50:00	3
611	7	7	SALE	24	2026-09-26 11:15:00	3
612	7	7	SALE	25	2026-09-27 13:41:00	3
613	7	7	SALE	13	2026-09-28 10:15:00	3
614	7	7	SALE	14	2026-09-29 17:38:00	3
615	7	7	SALE	21	2026-09-30 18:46:00	3
616	7	7	SALE	21	2026-10-01 18:18:00	3
617	7	7	SALE	14	2026-10-02 20:01:00	3
618	7	7	SALE	28	2026-10-03 19:56:00	3
619	7	7	SALE	28	2026-10-04 13:13:00	3
620	7	7	SALE	25	2026-10-05 17:38:00	3
621	7	7	SALE	15	2026-10-06 17:12:00	3
622	7	7	SALE	18	2026-10-07 20:25:00	3
623	7	7	SALE	20	2026-10-08 13:41:00	3
624	7	7	SALE	18	2026-10-09 09:50:00	3
625	7	7	SALE	24	2026-10-10 12:31:00	3
626	7	7	SALE	26	2026-10-11 15:07:00	3
627	7	7	SALE	20	2026-10-12 12:31:00	3
628	7	7	SALE	18	2026-10-13 19:38:00	3
629	7	7	SALE	20	2026-10-14 10:33:00	3
630	7	7	SALE	14	2026-10-15 09:23:00	3
631	7	7	SALE	23	2026-10-16 14:08:00	3
632	7	7	SALE	21	2026-10-17 15:55:00	3
633	7	7	SALE	28	2026-10-18 18:26:00	3
634	7	7	SALE	24	2026-10-19 14:34:00	3
635	7	7	SALE	18	2026-10-20 19:11:00	3
636	7	7	SALE	20	2026-10-21 16:49:00	3
637	7	7	SALE	15	2026-10-22 10:01:00	3
638	8	8	RECEIPT	3294	2026-07-25 08:00:00	2
639	8	8	SALE	39	2026-07-25 09:10:00	3
640	8	8	SALE	38	2026-07-26 18:27:00	3
641	8	8	SALE	23	2026-07-27 20:25:00	3
642	8	8	SALE	33	2026-07-28 16:01:00	3
643	8	8	SALE	19	2026-07-29 15:43:00	3
644	8	8	SALE	29	2026-07-30 15:11:00	3
645	8	8	SALE	27	2026-07-31 14:13:00	3
646	8	8	SALE	38	2026-08-01 11:17:00	3
647	8	8	SALE	27	2026-08-02 13:28:00	3
648	8	8	SALE	21	2026-08-03 11:02:00	3
649	8	8	SALE	23	2026-08-04 18:39:00	3
650	8	8	SALE	30	2026-08-05 18:15:00	3
651	8	8	SALE	25	2026-08-06 19:18:00	3
652	8	8	SALE	36	2026-08-07 16:26:00	3
653	8	8	SALE	29	2026-08-08 17:30:00	3
654	8	8	SALE	26	2026-08-09 09:05:00	3
655	8	8	SALE	31	2026-08-10 13:24:00	3
656	8	8	SALE	25	2026-08-11 11:26:00	3
657	8	8	SALE	27	2026-08-12 12:41:00	3
658	8	8	SALE	22	2026-08-13 17:15:00	3
659	8	8	SALE	31	2026-08-14 19:51:00	3
660	8	8	SALE	31	2026-08-15 17:50:00	3
661	8	8	SALE	31	2026-08-16 09:24:00	3
662	8	8	SALE	24	2026-08-17 20:22:00	3
663	8	8	SALE	19	2026-08-18 16:34:00	3
664	8	8	SALE	25	2026-08-19 16:22:00	3
665	8	8	SALE	26	2026-08-20 18:32:00	3
666	8	8	SALE	28	2026-08-21 14:24:00	3
667	8	8	SALE	120	2026-08-22 13:11:00	3
668	8	8	SALE	38	2026-08-23 09:20:00	3
669	8	8	SALE	18	2026-08-24 18:14:00	3
670	8	8	SALE	33	2026-08-25 09:57:00	3
671	8	8	SALE	34	2026-08-26 13:03:00	3
672	8	8	SALE	27	2026-08-27 16:33:00	3
673	8	8	SALE	26	2026-08-28 14:49:00	3
674	8	8	SALE	38	2026-08-29 18:14:00	3
675	8	8	SALE	41	2026-08-30 11:06:00	3
676	8	8	SALE	30	2026-08-31 12:42:00	3
677	8	8	SALE	23	2026-09-01 12:17:00	3
678	8	8	SALE	25	2026-09-02 17:52:00	3
679	8	8	SALE	31	2026-09-03 20:03:00	3
680	8	8	SALE	19	2026-09-04 12:36:00	3
681	8	8	SALE	32	2026-09-05 15:22:00	3
682	8	8	SALE	39	2026-09-06 11:11:00	3
683	8	8	SALE	16	2026-09-07 12:37:00	3
684	8	8	SALE	35	2026-09-08 14:51:00	3
685	8	8	SALE	24	2026-09-09 20:44:00	3
686	8	8	SALE	19	2026-09-10 14:58:00	3
687	8	8	SALE	26	2026-09-11 18:01:00	3
688	8	8	SALE	35	2026-09-12 20:44:00	3
689	8	8	SALE	28	2026-09-13 14:36:00	3
690	8	8	SALE	32	2026-09-14 18:09:00	3
691	8	8	SALE	24	2026-09-15 18:12:00	3
692	8	8	SALE	28	2026-09-16 16:34:00	3
693	8	8	SALE	38	2026-09-17 13:11:00	3
694	8	8	SALE	22	2026-09-18 16:02:00	3
695	8	8	SALE	34	2026-09-19 10:03:00	3
696	8	8	SALE	47	2026-09-20 12:38:00	3
697	8	8	SALE	25	2026-09-21 12:01:00	3
698	8	8	SALE	18	2026-09-22 17:30:00	3
699	8	8	SALE	20	2026-09-23 09:21:00	3
700	8	8	SALE	29	2026-09-24 18:12:00	3
701	8	8	SALE	28	2026-09-25 11:21:00	3
702	8	8	SALE	40	2026-09-26 20:11:00	3
703	8	8	SALE	34	2026-09-27 14:03:00	3
704	8	8	SALE	30	2026-09-28 09:09:00	3
705	8	8	SALE	31	2026-09-29 18:45:00	3
706	8	8	SALE	31	2026-09-30 11:49:00	3
707	8	8	SALE	21	2026-10-01 10:54:00	3
708	8	8	SALE	26	2026-10-02 17:55:00	3
709	8	8	SALE	31	2026-10-03 14:04:00	3
710	8	8	SALE	35	2026-10-04 14:45:00	3
711	8	8	SALE	22	2026-10-05 19:25:00	3
712	8	8	SALE	32	2026-10-06 18:06:00	3
713	8	8	SALE	27	2026-10-07 14:19:00	3
714	8	8	SALE	23	2026-10-08 14:08:00	3
715	8	8	SALE	24	2026-10-09 11:46:00	3
716	8	8	SALE	38	2026-10-10 15:50:00	3
717	8	8	SALE	41	2026-10-11 19:31:00	3
718	8	8	SALE	20	2026-10-12 19:20:00	3
719	8	8	SALE	32	2026-10-13 11:45:00	3
720	8	8	SALE	30	2026-10-14 17:44:00	3
721	8	8	SALE	26	2026-10-15 18:50:00	3
722	8	8	SALE	22	2026-10-16 14:14:00	3
723	8	8	SALE	38	2026-10-17 19:37:00	3
724	8	8	SALE	36	2026-10-18 11:24:00	3
725	8	8	SALE	28	2026-10-19 13:46:00	3
726	8	8	SALE	25	2026-10-20 20:18:00	3
727	8	8	SALE	33	2026-10-21 11:11:00	3
728	8	8	SALE	30	2026-10-22 20:00:00	3
729	9	9	RECEIPT	4743	2026-07-25 08:00:00	2
730	9	9	SALE	65	2026-07-25 11:12:00	3
731	9	9	SALE	56	2026-07-26 12:53:00	3
732	9	9	SALE	25	2026-07-27 09:15:00	3
733	9	9	SALE	28	2026-07-28 09:29:00	3
734	9	9	SALE	22	2026-07-29 09:58:00	3
735	9	9	SALE	32	2026-07-30 14:45:00	3
736	9	9	SALE	41	2026-07-31 12:17:00	3
737	9	9	SALE	80	2026-08-01 14:52:00	3
738	9	9	SALE	46	2026-08-02 16:32:00	3
739	9	9	SALE	27	2026-08-03 15:40:00	3
740	9	9	SALE	39	2026-08-04 10:43:00	3
741	9	9	SALE	42	2026-08-05 09:15:00	3
742	9	9	SALE	47	2026-08-06 14:31:00	3
743	9	9	SALE	39	2026-08-07 18:28:00	3
744	9	9	SALE	50	2026-08-08 11:55:00	3
745	9	9	SALE	52	2026-08-09 16:37:00	3
746	9	9	SALE	46	2026-08-10 17:22:00	3
747	9	9	SALE	30	2026-08-11 14:10:00	3
748	9	9	SALE	52	2026-08-12 13:47:00	3
749	9	9	SALE	46	2026-08-13 20:05:00	3
750	9	9	SALE	42	2026-08-14 13:01:00	3
751	9	9	SALE	53	2026-08-15 15:03:00	3
752	9	9	SALE	58	2026-08-16 11:54:00	3
753	9	9	SALE	37	2026-08-17 18:49:00	3
754	9	9	SALE	37	2026-08-18 12:54:00	3
755	9	9	SALE	39	2026-08-19 12:41:00	3
756	9	9	SALE	43	2026-08-20 12:43:00	3
757	9	9	SALE	36	2026-08-21 12:17:00	3
758	9	9	SALE	48	2026-08-22 19:26:00	3
759	9	9	SALE	41	2026-08-23 17:01:00	3
760	9	9	SALE	39	2026-08-24 19:00:00	3
761	9	9	SALE	41	2026-08-25 16:58:00	3
762	9	9	SALE	43	2026-08-26 11:41:00	3
763	9	9	SALE	45	2026-08-27 11:38:00	3
764	9	9	SALE	33	2026-08-28 09:14:00	3
765	9	9	SALE	42	2026-08-29 13:38:00	3
766	9	9	SALE	66	2026-08-30 13:45:00	3
767	9	9	SALE	46	2026-08-31 20:41:00	3
768	9	9	SALE	28	2026-09-01 13:27:00	3
769	9	9	SALE	40	2026-09-02 15:54:00	3
770	9	9	SALE	45	2026-09-03 14:29:00	3
771	9	9	SALE	54	2026-09-04 13:13:00	3
772	9	9	SALE	47	2026-09-05 16:19:00	3
773	9	9	SALE	52	2026-09-06 19:33:00	3
774	9	9	SALE	37	2026-09-07 18:25:00	3
775	9	9	SALE	36	2026-09-08 18:06:00	3
776	9	9	SALE	49	2026-09-09 09:32:00	3
777	9	9	SALE	37	2026-09-10 19:53:00	3
778	9	9	SALE	42	2026-09-11 14:35:00	3
779	9	9	SALE	50	2026-09-12 19:38:00	3
780	9	9	SALE	54	2026-09-13 18:18:00	3
781	9	9	SALE	39	2026-09-14 13:43:00	3
782	9	9	SALE	22	2026-09-15 10:30:00	3
783	9	9	SALE	39	2026-09-16 10:21:00	3
784	9	9	SALE	36	2026-09-17 13:40:00	3
785	9	9	SALE	36	2026-09-18 14:55:00	3
786	9	9	SALE	72	2026-09-19 13:16:00	3
787	9	9	SALE	52	2026-09-20 19:45:00	3
788	9	9	SALE	14	2026-09-21 19:19:00	3
789	9	9	SALE	50	2026-09-22 12:09:00	3
790	9	9	SALE	38	2026-09-23 17:48:00	3
791	9	9	SALE	56	2026-09-24 12:57:00	3
792	9	9	SALE	33	2026-09-25 09:51:00	3
793	9	9	SALE	58	2026-09-26 18:25:00	3
794	9	9	SALE	60	2026-09-27 19:20:00	3
795	9	9	SALE	28	2026-09-28 19:08:00	3
796	9	9	SALE	35	2026-09-29 20:01:00	3
797	9	9	SALE	41	2026-09-30 19:31:00	3
798	9	9	SALE	55	2026-10-01 13:16:00	3
799	9	9	SALE	32	2026-10-02 15:25:00	3
800	9	9	SALE	46	2026-10-03 15:47:00	3
801	9	9	SALE	52	2026-10-04 09:37:00	3
802	9	9	SALE	37	2026-10-05 20:36:00	3
803	9	9	SALE	38	2026-10-06 12:21:00	3
804	9	9	SALE	30	2026-10-07 20:45:00	3
805	9	9	SALE	31	2026-10-08 12:43:00	3
806	9	9	SALE	36	2026-10-09 17:40:00	3
807	9	9	SALE	63	2026-10-10 16:58:00	3
808	9	9	SALE	54	2026-10-11 19:22:00	3
809	9	9	SALE	33	2026-10-12 17:19:00	3
810	9	9	SALE	38	2026-10-13 11:53:00	3
811	9	9	SALE	36	2026-10-14 19:56:00	3
812	9	9	SALE	47	2026-10-15 17:11:00	3
813	9	9	SALE	38	2026-10-16 13:06:00	3
814	9	9	SALE	51	2026-10-17 16:08:00	3
815	9	9	SALE	53	2026-10-18 20:16:00	3
816	9	9	SALE	40	2026-10-19 20:51:00	3
817	9	9	SALE	23	2026-10-20 17:48:00	3
818	9	9	SALE	43	2026-10-21 11:43:00	3
819	9	9	SALE	45	2026-10-22 14:41:00	3
820	10	10	RECEIPT	2031	2026-07-25 08:00:00	2
821	10	10	SALE	19	2026-07-25 09:41:00	3
822	10	10	SALE	29	2026-07-26 11:32:00	3
823	10	10	SALE	17	2026-07-27 16:54:00	3
824	10	10	SALE	20	2026-07-28 16:55:00	3
825	10	10	SALE	20	2026-07-29 11:04:00	3
826	10	10	SALE	14	2026-07-30 16:20:00	3
827	10	10	SALE	20	2026-07-31 12:21:00	3
828	10	10	SALE	21	2026-08-01 13:03:00	3
829	10	10	SALE	23	2026-08-02 17:14:00	3
830	10	10	SALE	16	2026-08-03 17:41:00	3
831	10	10	SALE	10	2026-08-04 15:25:00	3
832	10	10	SALE	14	2026-08-05 12:05:00	3
833	10	10	SALE	16	2026-08-06 16:28:00	3
834	10	10	SALE	11	2026-08-07 18:28:00	3
835	10	10	SALE	22	2026-08-08 10:54:00	3
836	10	10	SALE	24	2026-08-09 16:28:00	3
837	10	10	SALE	17	2026-08-10 14:07:00	3
838	10	10	SALE	13	2026-08-11 16:47:00	3
839	10	10	SALE	13	2026-08-12 19:01:00	3
840	10	10	SALE	14	2026-08-13 10:25:00	3
841	10	10	SALE	16	2026-08-14 15:02:00	3
842	10	10	SALE	56	2026-08-15 17:35:00	3
843	10	10	SALE	27	2026-08-16 09:52:00	3
844	10	10	SALE	22	2026-08-17 10:50:00	3
845	10	10	SALE	16	2026-08-18 18:39:00	3
846	10	10	SALE	14	2026-08-19 19:19:00	3
847	10	10	SALE	15	2026-08-20 17:35:00	3
848	10	10	SALE	16	2026-08-21 12:41:00	3
849	10	10	SALE	22	2026-08-22 19:29:00	3
850	10	10	SALE	21	2026-08-23 14:23:00	3
851	10	10	SALE	13	2026-08-24 09:52:00	3
852	10	10	SALE	23	2026-08-25 12:54:00	3
853	10	10	SALE	24	2026-08-26 16:21:00	3
854	10	10	SALE	15	2026-08-27 17:49:00	3
855	10	10	SALE	17	2026-08-28 18:38:00	3
856	10	10	SALE	22	2026-08-29 16:45:00	3
857	10	10	SALE	23	2026-08-30 19:23:00	3
858	10	10	SALE	16	2026-08-31 20:28:00	3
859	10	10	SALE	16	2026-09-01 10:06:00	3
860	10	10	SALE	17	2026-09-02 19:14:00	3
861	10	10	SALE	17	2026-09-03 09:21:00	3
862	10	10	SALE	16	2026-09-04 14:53:00	3
863	10	10	SALE	20	2026-09-05 19:51:00	3
864	10	10	SALE	23	2026-09-06 13:35:00	3
865	10	10	SALE	15	2026-09-07 17:23:00	3
866	10	10	SALE	22	2026-09-08 20:06:00	3
867	10	10	SALE	16	2026-09-09 09:57:00	3
868	10	10	SALE	16	2026-09-10 11:31:00	3
869	10	10	SALE	17	2026-09-11 11:52:00	3
870	10	10	SALE	21	2026-09-12 20:47:00	3
871	10	10	SALE	22	2026-09-13 20:26:00	3
872	10	10	SALE	21	2026-09-14 10:16:00	3
873	10	10	SALE	17	2026-09-15 18:12:00	3
874	10	10	SALE	18	2026-09-16 12:07:00	3
875	10	10	SALE	53	2026-09-17 15:13:00	3
876	10	10	SALE	16	2026-09-18 16:52:00	3
877	10	10	SALE	24	2026-09-19 12:45:00	3
878	10	10	SALE	22	2026-09-20 14:06:00	3
879	10	10	SALE	19	2026-09-21 15:02:00	3
880	10	10	SALE	19	2026-09-22 19:53:00	3
881	10	10	SALE	16	2026-09-23 19:37:00	3
882	10	10	SALE	21	2026-09-24 10:49:00	3
883	10	10	SALE	20	2026-09-25 16:29:00	3
884	10	10	SALE	24	2026-09-26 19:37:00	3
885	10	10	SALE	22	2026-09-27 17:08:00	3
886	10	10	SALE	16	2026-09-28 16:00:00	3
887	10	10	SALE	19	2026-09-29 17:47:00	3
888	10	10	SALE	20	2026-09-30 09:35:00	3
889	10	10	SALE	18	2026-10-01 15:53:00	3
890	10	10	SALE	16	2026-10-02 18:30:00	3
891	10	10	SALE	26	2026-10-03 17:49:00	3
892	10	10	SALE	24	2026-10-04 11:44:00	3
893	10	10	SALE	13	2026-10-05 18:11:00	3
894	10	10	SALE	12	2026-10-06 20:52:00	3
895	10	10	SALE	25	2026-10-07 11:06:00	3
896	10	10	SALE	20	2026-10-08 15:42:00	3
897	10	10	SALE	12	2026-10-09 18:38:00	3
898	10	10	SALE	19	2026-10-10 14:32:00	3
899	10	10	SALE	28	2026-10-11 15:26:00	3
900	10	10	SALE	18	2026-10-12 18:58:00	3
901	10	10	SALE	22	2026-10-13 20:48:00	3
902	10	10	SALE	23	2026-10-14 12:17:00	3
903	10	10	SALE	20	2026-10-15 15:21:00	3
904	10	10	SALE	18	2026-10-16 13:28:00	3
905	10	10	SALE	25	2026-10-17 11:08:00	3
906	10	10	SALE	21	2026-10-18 15:38:00	3
907	10	10	SALE	15	2026-10-19 20:56:00	3
908	10	10	SALE	21	2026-10-20 20:32:00	3
909	10	10	SALE	16	2026-10-21 13:53:00	3
910	10	10	SALE	15	2026-10-22 20:35:00	3
911	11	11	RECEIPT	4862	2026-07-25 08:00:00	2
912	11	11	SALE	52	2026-07-25 12:26:00	3
913	11	11	SALE	34	2026-07-26 19:54:00	3
914	11	11	SALE	36	2026-07-27 17:09:00	3
915	11	11	SALE	45	2026-07-28 11:11:00	3
916	11	11	SALE	27	2026-07-29 12:39:00	3
917	11	11	SALE	22	2026-07-30 13:12:00	3
918	11	11	SALE	36	2026-07-31 10:11:00	3
919	11	11	SALE	56	2026-08-01 19:51:00	3
920	11	11	SALE	44	2026-08-02 18:54:00	3
921	11	11	SALE	44	2026-08-03 09:54:00	3
922	11	11	SALE	46	2026-08-04 17:29:00	3
923	11	11	SALE	27	2026-08-05 19:35:00	3
924	11	11	SALE	45	2026-08-06 10:18:00	3
925	11	11	SALE	47	2026-08-07 19:04:00	3
926	11	11	SALE	49	2026-08-08 13:06:00	3
927	11	11	SALE	60	2026-08-09 12:46:00	3
928	11	11	SALE	38	2026-08-10 18:31:00	3
929	11	11	SALE	36	2026-08-11 14:22:00	3
930	11	11	SALE	46	2026-08-12 11:42:00	3
931	11	11	SALE	29	2026-08-13 19:15:00	3
932	11	11	SALE	33	2026-08-14 10:18:00	3
933	11	11	SALE	53	2026-08-15 18:04:00	3
934	11	11	SALE	61	2026-08-16 12:20:00	3
935	11	11	SALE	35	2026-08-17 16:28:00	3
936	11	11	SALE	77	2026-08-18 14:39:00	3
937	11	11	SALE	47	2026-08-19 19:19:00	3
938	11	11	SALE	41	2026-08-20 20:37:00	3
939	11	11	SALE	23	2026-08-21 11:36:00	3
940	11	11	SALE	47	2026-08-22 18:23:00	3
941	11	11	SALE	44	2026-08-23 14:27:00	3
942	11	11	SALE	44	2026-08-24 11:00:00	3
943	11	11	SALE	37	2026-08-25 14:15:00	3
944	11	11	SALE	40	2026-08-26 12:45:00	3
945	11	11	SALE	42	2026-08-27 20:41:00	3
946	11	11	SALE	29	2026-08-28 15:17:00	3
947	11	11	SALE	58	2026-08-29 14:08:00	3
948	11	11	SALE	51	2026-08-30 19:46:00	3
949	11	11	SALE	34	2026-08-31 14:56:00	3
950	11	11	SALE	55	2026-09-01 16:29:00	3
951	11	11	SALE	44	2026-09-02 16:22:00	3
952	11	11	SALE	28	2026-09-03 13:31:00	3
953	11	11	SALE	39	2026-09-04 17:06:00	3
954	11	11	SALE	53	2026-09-05 11:41:00	3
955	11	11	SALE	58	2026-09-06 18:05:00	3
956	11	11	SALE	35	2026-09-07 13:54:00	3
957	11	11	SALE	37	2026-09-08 11:57:00	3
958	11	11	SALE	34	2026-09-09 17:12:00	3
959	11	11	SALE	44	2026-09-10 13:46:00	3
960	11	11	SALE	13	2026-09-11 19:04:00	3
961	11	11	SALE	139	2026-09-12 20:04:00	3
962	11	11	SALE	61	2026-09-13 09:54:00	3
963	11	11	SALE	32	2026-09-14 17:40:00	3
964	11	11	SALE	35	2026-09-15 09:52:00	3
965	11	11	SALE	32	2026-09-16 18:37:00	3
966	11	11	SALE	31	2026-09-17 15:49:00	3
967	11	11	SALE	44	2026-09-18 18:13:00	3
968	11	11	SALE	46	2026-09-19 09:35:00	3
969	11	11	SALE	59	2026-09-20 13:34:00	3
970	11	11	SALE	41	2026-09-21 17:30:00	3
971	11	11	SALE	47	2026-09-22 19:49:00	3
972	11	11	SALE	97	2026-09-23 11:23:00	3
973	11	11	SALE	35	2026-09-24 15:14:00	3
974	11	11	SALE	40	2026-09-25 18:46:00	3
975	11	11	SALE	35	2026-09-26 13:08:00	3
976	11	11	SALE	68	2026-09-27 16:32:00	3
977	11	11	SALE	36	2026-09-28 17:05:00	3
978	11	11	SALE	38	2026-09-29 15:23:00	3
979	11	11	SALE	34	2026-09-30 17:00:00	3
980	11	11	SALE	40	2026-10-01 19:15:00	3
981	11	11	SALE	39	2026-10-02 18:43:00	3
982	11	11	SALE	55	2026-10-03 11:48:00	3
983	11	11	SALE	60	2026-10-04 17:08:00	3
984	11	11	SALE	49	2026-10-05 16:10:00	3
985	11	11	SALE	39	2026-10-06 11:36:00	3
986	11	11	SALE	29	2026-10-07 18:42:00	3
987	11	11	SALE	29	2026-10-08 11:47:00	3
988	11	11	SALE	54	2026-10-09 20:30:00	3
989	11	11	SALE	63	2026-10-10 14:02:00	3
990	11	11	SALE	51	2026-10-11 12:48:00	3
991	11	11	SALE	30	2026-10-12 16:14:00	3
992	11	11	SALE	29	2026-10-13 10:16:00	3
993	11	11	SALE	40	2026-10-14 14:14:00	3
994	11	11	SALE	41	2026-10-15 09:42:00	3
995	11	11	SALE	29	2026-10-16 12:33:00	3
996	11	11	SALE	66	2026-10-17 14:24:00	3
997	11	11	SALE	45	2026-10-18 16:58:00	3
998	11	11	SALE	29	2026-10-19 16:56:00	3
999	11	11	SALE	91	2026-10-20 09:02:00	3
1000	11	11	SALE	20	2026-10-21 19:20:00	3
1001	11	11	SALE	34	2026-10-22 10:45:00	3
1002	12	12	RECEIPT	2359	2026-07-25 08:00:00	2
1003	12	12	SALE	26	2026-07-25 10:51:00	3
1004	12	12	SALE	25	2026-07-26 17:16:00	3
1005	12	12	SALE	16	2026-07-27 17:52:00	3
1006	12	12	SALE	22	2026-07-28 18:16:00	3
1007	12	12	SALE	22	2026-07-29 20:28:00	3
1008	12	12	SALE	20	2026-07-30 15:36:00	3
1009	12	12	SALE	13	2026-07-31 16:49:00	3
1010	12	12	SALE	32	2026-08-01 12:48:00	3
1011	12	12	SALE	28	2026-08-02 14:49:00	3
1012	12	12	SALE	16	2026-08-03 16:43:00	3
1013	12	12	SALE	19	2026-08-04 16:57:00	3
1014	12	12	SALE	21	2026-08-05 18:55:00	3
1015	12	12	SALE	21	2026-08-06 09:30:00	3
1016	12	12	SALE	14	2026-08-07 10:16:00	3
1017	12	12	SALE	23	2026-08-08 10:24:00	3
1018	12	12	SALE	23	2026-08-09 19:50:00	3
1019	12	12	SALE	19	2026-08-10 12:43:00	3
1020	12	12	SALE	21	2026-08-11 20:14:00	3
1021	12	12	SALE	11	2026-08-12 14:26:00	3
1022	12	12	SALE	18	2026-08-13 14:33:00	3
1023	12	12	SALE	23	2026-08-14 17:00:00	3
1024	12	12	SALE	26	2026-08-15 20:53:00	3
1025	12	12	SALE	27	2026-08-16 13:15:00	3
1026	12	12	SALE	12	2026-08-17 13:05:00	3
1027	12	12	SALE	16	2026-08-18 15:43:00	3
1028	12	12	SALE	16	2026-08-19 20:52:00	3
1029	12	12	SALE	17	2026-08-20 14:04:00	3
1030	12	12	SALE	20	2026-08-21 17:59:00	3
1031	12	12	SALE	25	2026-08-22 11:30:00	3
1032	12	12	SALE	28	2026-08-23 14:22:00	3
1033	12	12	SALE	22	2026-08-24 12:57:00	3
1034	12	12	SALE	53	2026-08-25 18:17:00	3
1035	12	12	SALE	24	2026-08-26 11:47:00	3
1036	12	12	SALE	16	2026-08-27 19:59:00	3
1037	12	12	SALE	23	2026-08-28 12:31:00	3
1038	12	12	SALE	35	2026-08-29 20:12:00	3
1039	12	12	SALE	32	2026-08-30 12:47:00	3
1040	12	12	SALE	22	2026-08-31 12:55:00	3
1041	12	12	SALE	28	2026-09-01 13:13:00	3
1042	12	12	SALE	19	2026-09-02 12:12:00	3
1043	12	12	SALE	12	2026-09-03 12:53:00	3
1044	12	12	SALE	23	2026-09-04 18:22:00	3
1045	12	12	SALE	22	2026-09-05 11:49:00	3
1046	12	12	SALE	28	2026-09-06 10:07:00	3
1047	12	12	SALE	22	2026-09-07 10:43:00	3
1048	12	12	SALE	15	2026-09-08 19:31:00	3
1049	12	12	SALE	20	2026-09-09 18:00:00	3
1050	12	12	SALE	11	2026-09-10 17:02:00	3
1051	12	12	SALE	44	2026-09-11 16:23:00	3
1052	12	12	SALE	24	2026-09-12 18:20:00	3
1053	12	12	SALE	25	2026-09-13 16:57:00	3
1054	12	12	SALE	21	2026-09-14 18:55:00	3
1055	12	12	SALE	22	2026-09-15 13:31:00	3
1056	12	12	SALE	21	2026-09-16 11:48:00	3
1057	12	12	SALE	14	2026-09-17 17:17:00	3
1058	12	12	SALE	18	2026-09-18 15:14:00	3
1059	12	12	SALE	28	2026-09-19 18:08:00	3
1060	12	12	SALE	30	2026-09-20 09:33:00	3
1061	12	12	SALE	8	2026-09-21 15:30:00	3
1062	12	12	SALE	20	2026-09-22 17:02:00	3
1063	12	12	SALE	17	2026-09-23 17:22:00	3
1064	12	12	SALE	20	2026-09-24 15:55:00	3
1065	12	12	SALE	20	2026-09-25 19:49:00	3
1066	12	12	SALE	32	2026-09-26 11:29:00	3
1067	12	12	SALE	29	2026-09-27 10:44:00	3
1068	12	12	SALE	14	2026-09-28 17:29:00	3
1069	12	12	SALE	15	2026-09-29 14:44:00	3
1070	12	12	SALE	22	2026-09-30 09:00:00	3
1071	12	12	SALE	14	2026-10-01 19:13:00	3
1072	12	12	SALE	20	2026-10-02 15:37:00	3
1073	12	12	SALE	21	2026-10-03 10:20:00	3
1074	12	12	SALE	22	2026-10-04 14:39:00	3
1075	12	12	SALE	17	2026-10-05 13:11:00	3
1076	12	12	SALE	29	2026-10-06 17:16:00	3
1077	12	12	SALE	60	2026-10-07 12:17:00	3
1078	12	12	SALE	23	2026-10-08 16:39:00	3
1079	12	12	SALE	17	2026-10-09 14:23:00	3
1080	12	12	SALE	26	2026-10-10 11:31:00	3
1081	12	12	SALE	25	2026-10-11 15:13:00	3
1082	12	12	SALE	16	2026-10-12 15:44:00	3
1083	12	12	SALE	22	2026-10-13 14:23:00	3
1084	12	12	SALE	21	2026-10-14 15:17:00	3
1085	12	12	SALE	46	2026-10-15 16:11:00	3
1086	12	12	SALE	20	2026-10-16 18:08:00	3
1087	12	12	SALE	26	2026-10-17 18:43:00	3
1088	12	12	SALE	21	2026-10-18 12:52:00	3
1089	12	12	SALE	20	2026-10-19 10:46:00	3
1090	12	12	SALE	29	2026-10-20 13:51:00	3
1091	12	12	SALE	21	2026-10-21 12:35:00	3
1092	12	12	SALE	19	2026-10-22 15:54:00	3
1093	13	13	RECEIPT	2017	2026-07-25 08:00:00	2
1094	13	13	SALE	34	2026-07-25 09:55:00	3
1095	13	13	SALE	37	2026-07-26 19:13:00	3
1096	13	13	SALE	7	2026-07-27 10:15:00	3
1097	13	13	SALE	20	2026-07-28 19:27:00	3
1098	13	13	SALE	19	2026-07-29 14:00:00	3
1099	13	13	SALE	13	2026-07-30 11:50:00	3
1100	13	13	SALE	16	2026-07-31 13:37:00	3
1101	13	13	SALE	25	2026-08-01 10:25:00	3
1102	13	13	SALE	25	2026-08-02 12:00:00	3
1103	13	13	SALE	17	2026-08-03 09:37:00	3
1104	13	13	SALE	11	2026-08-04 20:30:00	3
1105	13	13	SALE	36	2026-08-05 20:38:00	3
1106	13	13	SALE	27	2026-08-06 11:23:00	3
1107	13	13	SALE	12	2026-08-07 10:15:00	3
1108	13	13	SALE	32	2026-08-08 11:31:00	3
1109	13	13	SALE	35	2026-08-09 10:43:00	3
1110	13	13	SALE	19	2026-08-10 18:21:00	3
1111	13	13	SALE	12	2026-08-11 19:03:00	3
1112	13	13	SALE	18	2026-08-12 09:22:00	3
1113	13	13	SALE	18	2026-08-13 19:09:00	3
1114	13	13	SALE	17	2026-08-14 20:34:00	3
1115	13	13	SALE	34	2026-08-15 10:08:00	3
1116	13	13	SALE	27	2026-08-16 16:14:00	3
1117	13	13	SALE	23	2026-08-17 14:35:00	3
1118	13	13	SALE	18	2026-08-18 19:48:00	3
1119	13	13	SALE	17	2026-08-19 14:51:00	3
1120	13	13	SALE	17	2026-08-20 16:46:00	3
1121	13	13	SALE	24	2026-08-21 12:01:00	3
1122	13	13	SALE	33	2026-08-22 20:24:00	3
1123	13	13	SALE	31	2026-08-23 14:46:00	3
1124	13	13	SALE	22	2026-08-24 11:16:00	3
1125	13	13	SALE	21	2026-08-25 09:31:00	3
1126	13	13	SALE	24	2026-08-26 20:28:00	3
1127	13	13	SALE	17	2026-08-27 17:18:00	3
1128	13	13	SALE	20	2026-08-28 17:44:00	3
1129	13	13	SALE	25	2026-08-29 16:12:00	3
1130	13	13	SALE	28	2026-08-30 18:11:00	3
1131	13	13	SALE	23	2026-08-31 17:22:00	3
1132	13	13	SALE	25	2026-09-01 14:46:00	3
1133	13	13	SALE	26	2026-09-02 16:17:00	3
1134	13	13	SALE	22	2026-09-03 18:58:00	3
1135	13	13	SALE	17	2026-09-04 17:10:00	3
1136	13	13	SALE	28	2026-09-05 10:33:00	3
1137	13	13	SALE	33	2026-09-06 11:28:00	3
1138	13	13	SALE	15	2026-09-07 13:52:00	3
1139	13	13	SALE	17	2026-09-08 13:34:00	3
1140	13	13	SALE	14	2026-09-09 14:29:00	3
1141	13	13	SALE	19	2026-09-10 09:49:00	3
1142	13	13	SALE	13	2026-09-11 19:32:00	3
1143	13	13	SALE	26	2026-09-12 15:46:00	3
1144	13	13	SALE	35	2026-09-13 11:56:00	3
1145	13	13	SALE	20	2026-09-14 09:39:00	3
1146	13	13	SALE	19	2026-09-15 14:49:00	3
1147	13	13	SALE	20	2026-09-16 18:15:00	3
1148	13	13	SALE	19	2026-09-17 14:46:00	3
1149	13	13	SALE	20	2026-09-18 10:42:00	3
1150	13	13	SALE	31	2026-09-19 17:52:00	3
1151	13	13	SALE	28	2026-09-20 15:12:00	3
1152	13	13	SALE	23	2026-09-21 17:43:00	3
1153	13	13	SALE	26	2026-09-22 16:49:00	3
1154	13	13	SALE	20	2026-09-23 17:09:00	3
1155	13	13	SALE	24	2026-09-24 18:18:00	3
1156	13	13	SALE	26	2026-09-25 14:26:00	3
1157	13	13	SALE	23	2026-09-26 19:20:00	3
1158	13	13	SALE	23	2026-09-27 10:06:00	3
1159	13	13	SALE	24	2026-09-28 17:42:00	3
1160	13	13	SALE	16	2026-09-29 10:02:00	3
1161	13	13	SALE	16	2026-09-30 11:11:00	3
1162	13	13	SALE	20	2026-10-01 09:12:00	3
1163	13	13	SALE	21	2026-10-02 10:31:00	3
1164	13	13	SALE	29	2026-10-03 12:06:00	3
1165	13	13	SALE	31	2026-10-04 09:36:00	3
1166	13	13	SALE	23	2026-10-05 19:53:00	3
1167	13	13	SALE	24	2026-10-06 15:42:00	3
1168	13	13	SALE	24	2026-10-07 16:33:00	3
1169	13	13	SALE	7	2026-10-08 18:44:00	3
1170	13	13	SALE	16	2026-10-09 18:16:00	3
1171	13	13	SALE	33	2026-10-10 09:23:00	3
1172	13	13	SALE	24	2026-10-11 12:38:00	3
1173	13	13	SALE	20	2026-10-12 20:04:00	3
1174	13	13	SALE	21	2026-10-13 09:59:00	3
1175	13	13	SALE	18	2026-10-14 12:41:00	3
1176	13	13	SALE	21	2026-10-15 16:59:00	3
1177	13	13	SALE	16	2026-10-16 10:29:00	3
1178	13	13	SALE	28	2026-10-17 19:03:00	3
1179	13	13	SALE	23	2026-10-18 14:35:00	3
1180	13	13	SALE	19	2026-10-19 20:56:00	3
1181	13	13	SALE	23	2026-10-20 15:52:00	3
1182	13	13	SALE	24	2026-10-21 14:50:00	3
1183	13	13	SALE	18	2026-10-22 20:03:00	3
1184	14	14	RECEIPT	3919	2026-07-25 08:00:00	2
1185	14	14	SALE	47	2026-07-25 16:25:00	3
1186	14	14	SALE	45	2026-07-26 20:10:00	3
1187	14	14	SALE	35	2026-07-27 09:22:00	3
1188	14	14	SALE	31	2026-07-28 19:22:00	3
1189	14	14	SALE	35	2026-07-29 14:40:00	3
1190	14	14	SALE	39	2026-07-30 13:15:00	3
1191	14	14	SALE	37	2026-07-31 17:17:00	3
1192	14	14	SALE	52	2026-08-01 09:40:00	3
1193	14	14	SALE	35	2026-08-02 13:56:00	3
1194	14	14	SALE	34	2026-08-03 15:56:00	3
1195	14	14	SALE	35	2026-08-04 09:35:00	3
1196	14	14	SALE	38	2026-08-05 13:14:00	3
1197	14	14	SALE	39	2026-08-06 11:21:00	3
1198	14	14	SALE	32	2026-08-07 15:42:00	3
1199	14	14	SALE	45	2026-08-08 11:05:00	3
1200	14	14	SALE	50	2026-08-09 20:24:00	3
1201	14	14	SALE	26	2026-08-10 17:43:00	3
1202	14	14	SALE	27	2026-08-11 18:55:00	3
1203	14	14	SALE	36	2026-08-12 19:43:00	3
1204	14	14	SALE	30	2026-08-13 12:26:00	3
1205	14	14	SALE	24	2026-08-14 12:36:00	3
1206	14	14	SALE	52	2026-08-15 11:27:00	3
1207	14	14	SALE	46	2026-08-16 13:58:00	3
1208	14	14	SALE	37	2026-08-17 18:21:00	3
1209	14	14	SALE	44	2026-08-18 16:34:00	3
1210	14	14	SALE	34	2026-08-19 11:13:00	3
1211	14	14	SALE	24	2026-08-20 19:08:00	3
1212	14	14	SALE	29	2026-08-21 18:34:00	3
1213	14	14	SALE	40	2026-08-22 19:51:00	3
1214	14	14	SALE	48	2026-08-23 12:55:00	3
1215	14	14	SALE	33	2026-08-24 11:19:00	3
1216	14	14	SALE	29	2026-08-25 20:45:00	3
1217	14	14	SALE	31	2026-08-26 17:58:00	3
1218	14	14	SALE	22	2026-08-27 11:27:00	3
1219	14	14	SALE	36	2026-08-28 11:41:00	3
1220	14	14	SALE	39	2026-08-29 18:58:00	3
1221	14	14	SALE	43	2026-08-30 11:20:00	3
1222	14	14	SALE	24	2026-08-31 10:35:00	3
1223	14	14	SALE	33	2026-09-01 17:46:00	3
1224	14	14	SALE	26	2026-09-02 10:11:00	3
1225	14	14	SALE	41	2026-09-03 14:53:00	3
1226	14	14	SALE	22	2026-09-04 11:46:00	3
1227	14	14	SALE	57	2026-09-05 09:48:00	3
1228	14	14	SALE	44	2026-09-06 14:56:00	3
1229	14	14	SALE	28	2026-09-07 15:26:00	3
1230	14	14	SALE	31	2026-09-08 13:28:00	3
1231	14	14	SALE	42	2026-09-09 20:59:00	3
1232	14	14	SALE	35	2026-09-10 19:59:00	3
1233	14	14	SALE	26	2026-09-11 20:17:00	3
1234	14	14	SALE	39	2026-09-12 11:49:00	3
1235	14	14	SALE	50	2026-09-13 12:06:00	3
1236	14	14	SALE	36	2026-09-14 11:11:00	3
1237	14	14	SALE	39	2026-09-15 09:48:00	3
1238	14	14	SALE	36	2026-09-16 18:39:00	3
1239	14	14	SALE	37	2026-09-17 13:38:00	3
1240	14	14	SALE	38	2026-09-18 18:39:00	3
1241	14	14	SALE	35	2026-09-19 12:38:00	3
1242	14	14	SALE	35	2026-09-20 12:14:00	3
1243	14	14	SALE	26	2026-09-21 19:01:00	3
1244	14	14	SALE	45	2026-09-22 14:05:00	3
1245	14	14	SALE	27	2026-09-23 20:49:00	3
1246	14	14	SALE	35	2026-09-24 16:08:00	3
1247	14	14	SALE	37	2026-09-25 17:54:00	3
1248	14	14	SALE	46	2026-09-26 18:30:00	3
1249	14	14	SALE	46	2026-09-27 20:41:00	3
1250	14	14	SALE	34	2026-09-28 14:11:00	3
1251	14	14	SALE	24	2026-09-29 15:31:00	3
1252	14	14	SALE	40	2026-09-30 16:08:00	3
1253	14	14	SALE	47	2026-10-01 11:12:00	3
1254	14	14	SALE	37	2026-10-02 12:02:00	3
1255	14	14	SALE	57	2026-10-03 15:48:00	3
1256	14	14	SALE	45	2026-10-04 09:59:00	3
1257	14	14	SALE	34	2026-10-05 13:26:00	3
1258	14	14	SALE	40	2026-10-06 12:47:00	3
1259	14	14	SALE	32	2026-10-07 19:12:00	3
1260	14	14	SALE	39	2026-10-08 12:04:00	3
1261	14	14	SALE	32	2026-10-09 11:59:00	3
1262	14	14	SALE	45	2026-10-10 16:55:00	3
1263	14	14	SALE	40	2026-10-11 18:31:00	3
1264	14	14	SALE	43	2026-10-12 20:20:00	3
1265	14	14	SALE	32	2026-10-13 16:56:00	3
1266	14	14	SALE	31	2026-10-14 12:27:00	3
1267	14	14	SALE	38	2026-10-15 15:49:00	3
1268	14	14	SALE	69	2026-10-16 09:38:00	3
1269	14	14	SALE	46	2026-10-17 20:52:00	3
1270	14	14	SALE	48	2026-10-18 15:46:00	3
1271	14	14	SALE	37	2026-10-19 14:25:00	3
1272	14	14	SALE	26	2026-10-20 18:47:00	3
1273	14	14	SALE	18	2026-10-21 18:38:00	3
1274	14	14	SALE	36	2026-10-22 17:33:00	3
1275	15	15	RECEIPT	4613	2026-07-25 08:00:00	2
1276	15	15	SALE	55	2026-07-25 20:02:00	3
1277	15	15	SALE	52	2026-07-26 13:26:00	3
1278	15	15	SALE	43	2026-07-27 10:31:00	3
1279	15	15	SALE	35	2026-07-28 12:23:00	3
1280	15	15	SALE	46	2026-07-29 16:53:00	3
1281	15	15	SALE	41	2026-07-30 13:13:00	3
1282	15	15	SALE	42	2026-07-31 17:19:00	3
1283	15	15	SALE	65	2026-08-01 11:07:00	3
1284	15	15	SALE	47	2026-08-02 14:50:00	3
1285	15	15	SALE	56	2026-08-03 09:49:00	3
1286	15	15	SALE	28	2026-08-04 12:58:00	3
1287	15	15	SALE	42	2026-08-05 10:28:00	3
1288	15	15	SALE	43	2026-08-06 17:01:00	3
1289	15	15	SALE	48	2026-08-07 16:57:00	3
1290	15	15	SALE	53	2026-08-08 17:09:00	3
1291	15	15	SALE	59	2026-08-09 12:21:00	3
1292	15	15	SALE	42	2026-08-10 16:46:00	3
1293	15	15	SALE	37	2026-08-11 17:19:00	3
1294	15	15	SALE	38	2026-08-12 14:09:00	3
1295	15	15	SALE	34	2026-08-13 10:52:00	3
1296	15	15	SALE	36	2026-08-14 17:43:00	3
1297	15	15	SALE	46	2026-08-15 11:13:00	3
1298	15	15	SALE	55	2026-08-16 20:02:00	3
1299	15	15	SALE	36	2026-08-17 16:24:00	3
1300	15	15	SALE	42	2026-08-18 20:55:00	3
1301	15	15	SALE	45	2026-08-19 17:07:00	3
1302	15	15	SALE	41	2026-08-20 09:19:00	3
1303	15	15	SALE	43	2026-08-21 09:43:00	3
1304	15	15	SALE	51	2026-08-22 18:55:00	3
1305	15	15	SALE	32	2026-08-23 10:21:00	3
1306	15	15	SALE	40	2026-08-24 16:56:00	3
1307	15	15	SALE	97	2026-08-25 09:06:00	3
1308	15	15	SALE	25	2026-08-26 17:49:00	3
1309	15	15	SALE	39	2026-08-27 19:47:00	3
1310	15	15	SALE	41	2026-08-28 13:01:00	3
1311	15	15	SALE	65	2026-08-29 18:48:00	3
1312	15	15	SALE	55	2026-08-30 13:40:00	3
1313	15	15	SALE	35	2026-08-31 12:20:00	3
1314	15	15	SALE	40	2026-09-01 12:12:00	3
1315	15	15	SALE	44	2026-09-02 13:17:00	3
1316	15	15	SALE	40	2026-09-03 17:20:00	3
1317	15	15	SALE	41	2026-09-04 16:42:00	3
1318	15	15	SALE	56	2026-09-05 10:17:00	3
1319	15	15	SALE	54	2026-09-06 11:10:00	3
1320	15	15	SALE	33	2026-09-07 13:07:00	3
1321	15	15	SALE	29	2026-09-08 09:39:00	3
1322	15	15	SALE	52	2026-09-09 17:32:00	3
1323	15	15	SALE	36	2026-09-10 10:13:00	3
1324	15	15	SALE	40	2026-09-11 17:22:00	3
1325	15	15	SALE	50	2026-09-12 17:20:00	3
1326	15	15	SALE	65	2026-09-13 13:09:00	3
1327	15	15	SALE	42	2026-09-14 20:51:00	3
1328	15	15	SALE	35	2026-09-15 13:36:00	3
1329	15	15	SALE	46	2026-09-16 12:10:00	3
1330	15	15	SALE	48	2026-09-17 10:19:00	3
1331	15	15	SALE	43	2026-09-18 18:57:00	3
1332	15	15	SALE	50	2026-09-19 14:34:00	3
1333	15	15	SALE	46	2026-09-20 16:03:00	3
1334	15	15	SALE	42	2026-09-21 11:01:00	3
1335	15	15	SALE	34	2026-09-22 16:57:00	3
1336	15	15	SALE	49	2026-09-23 19:03:00	3
1337	15	15	SALE	34	2026-09-24 10:24:00	3
1338	15	15	SALE	25	2026-09-25 09:05:00	3
1339	15	15	SALE	53	2026-09-26 15:25:00	3
1340	15	15	SALE	59	2026-09-27 11:45:00	3
1341	15	15	SALE	45	2026-09-28 18:57:00	3
1342	15	15	SALE	42	2026-09-29 18:40:00	3
1343	15	15	SALE	49	2026-09-30 20:44:00	3
1344	15	15	SALE	31	2026-10-01 16:39:00	3
1345	15	15	SALE	50	2026-10-02 14:19:00	3
1346	15	15	SALE	56	2026-10-03 14:52:00	3
1347	15	15	SALE	58	2026-10-04 12:45:00	3
1348	15	15	SALE	44	2026-10-05 19:51:00	3
1349	15	15	SALE	44	2026-10-06 17:05:00	3
1350	15	15	SALE	53	2026-10-07 16:36:00	3
1351	15	15	SALE	35	2026-10-08 11:05:00	3
1352	15	15	SALE	47	2026-10-09 20:29:00	3
1353	15	15	SALE	47	2026-10-10 10:29:00	3
1354	15	15	SALE	37	2026-10-11 13:43:00	3
1355	15	15	SALE	43	2026-10-12 19:45:00	3
1356	15	15	SALE	46	2026-10-13 16:30:00	3
1357	15	15	SALE	23	2026-10-14 12:14:00	3
1358	15	15	SALE	28	2026-10-15 11:55:00	3
1359	15	15	SALE	88	2026-10-16 18:16:00	3
1360	15	15	SALE	65	2026-10-17 14:25:00	3
1361	15	15	SALE	45	2026-10-18 11:44:00	3
1362	15	15	SALE	35	2026-10-19 19:21:00	3
1363	15	15	SALE	45	2026-10-20 14:29:00	3
1364	15	15	SALE	35	2026-10-21 16:01:00	3
1365	15	15	SALE	36	2026-10-22 10:30:00	3
1366	16	16	RECEIPT	3347	2026-07-25 08:00:00	2
1367	16	16	SALE	29	2026-07-25 15:30:00	3
1368	16	16	SALE	44	2026-07-26 13:30:00	3
1369	16	16	SALE	25	2026-07-27 20:48:00	3
1370	16	16	SALE	31	2026-07-28 17:14:00	3
1371	16	16	SALE	29	2026-07-29 15:43:00	3
1372	16	16	SALE	30	2026-07-30 20:24:00	3
1373	16	16	SALE	27	2026-07-31 16:16:00	3
1374	16	16	SALE	39	2026-08-01 11:33:00	3
1375	16	16	SALE	43	2026-08-02 15:00:00	3
1376	16	16	SALE	40	2026-08-03 13:59:00	3
1377	16	16	SALE	26	2026-08-04 16:24:00	3
1378	16	16	SALE	29	2026-08-05 19:20:00	3
1379	16	16	SALE	26	2026-08-06 17:43:00	3
1380	16	16	SALE	22	2026-08-07 09:06:00	3
1381	16	16	SALE	36	2026-08-08 17:40:00	3
1382	16	16	SALE	40	2026-08-09 14:54:00	3
1383	16	16	SALE	24	2026-08-10 15:39:00	3
1384	16	16	SALE	36	2026-08-11 19:54:00	3
1385	16	16	SALE	33	2026-08-12 13:21:00	3
1386	16	16	SALE	26	2026-08-13 13:17:00	3
1387	16	16	SALE	32	2026-08-14 10:16:00	3
1388	16	16	SALE	48	2026-08-15 19:37:00	3
1389	16	16	SALE	41	2026-08-16 15:29:00	3
1390	16	16	SALE	25	2026-08-17 19:47:00	3
1391	16	16	SALE	27	2026-08-18 12:46:00	3
1392	16	16	SALE	32	2026-08-19 19:37:00	3
1393	16	16	SALE	34	2026-08-20 12:33:00	3
1394	16	16	SALE	22	2026-08-21 14:43:00	3
1395	16	16	SALE	61	2026-08-22 20:11:00	3
1396	16	16	SALE	34	2026-08-23 14:35:00	3
1397	16	16	SALE	38	2026-08-24 09:43:00	3
1398	16	16	SALE	21	2026-08-25 09:53:00	3
1399	16	16	SALE	31	2026-08-26 10:00:00	3
1400	16	16	SALE	31	2026-08-27 15:06:00	3
1401	16	16	SALE	35	2026-08-28 17:06:00	3
1402	16	16	SALE	46	2026-08-29 19:28:00	3
1403	16	16	SALE	43	2026-08-30 14:14:00	3
1404	16	16	SALE	25	2026-08-31 20:18:00	3
1405	16	16	SALE	33	2026-09-01 13:12:00	3
1406	16	16	SALE	34	2026-09-02 09:01:00	3
1407	16	16	SALE	27	2026-09-03 18:05:00	3
1408	16	16	SALE	36	2026-09-04 09:38:00	3
1409	16	16	SALE	50	2026-09-05 19:57:00	3
1410	16	16	SALE	46	2026-09-06 12:38:00	3
1411	16	16	SALE	34	2026-09-07 19:07:00	3
1412	16	16	SALE	30	2026-09-08 20:07:00	3
1413	16	16	SALE	39	2026-09-09 10:54:00	3
1414	16	16	SALE	21	2026-09-10 18:08:00	3
1415	16	16	SALE	26	2026-09-11 15:42:00	3
1416	16	16	SALE	41	2026-09-12 19:36:00	3
1417	16	16	SALE	41	2026-09-13 11:57:00	3
1418	16	16	SALE	31	2026-09-14 10:44:00	3
1419	16	16	SALE	30	2026-09-15 11:16:00	3
1420	16	16	SALE	26	2026-09-16 13:29:00	3
1421	16	16	SALE	33	2026-09-17 19:59:00	3
1422	16	16	SALE	31	2026-09-18 10:40:00	3
1423	16	16	SALE	46	2026-09-19 16:59:00	3
1424	16	16	SALE	43	2026-09-20 13:49:00	3
1425	16	16	SALE	31	2026-09-21 15:44:00	3
1426	16	16	SALE	26	2026-09-22 19:49:00	3
1427	16	16	SALE	27	2026-09-23 14:16:00	3
1428	16	16	SALE	28	2026-09-24 11:49:00	3
1429	16	16	SALE	26	2026-09-25 10:17:00	3
1430	16	16	SALE	36	2026-09-26 09:24:00	3
1431	16	16	SALE	45	2026-09-27 15:21:00	3
1432	16	16	SALE	31	2026-09-28 09:16:00	3
1433	16	16	SALE	26	2026-09-29 13:11:00	3
1434	16	16	SALE	29	2026-09-30 16:04:00	3
1435	16	16	SALE	30	2026-10-01 16:59:00	3
1436	16	16	SALE	35	2026-10-02 12:39:00	3
1437	16	16	SALE	43	2026-10-03 15:11:00	3
1438	16	16	SALE	39	2026-10-04 19:31:00	3
1439	16	16	SALE	28	2026-10-05 10:09:00	3
1440	16	16	SALE	27	2026-10-06 17:49:00	3
1441	16	16	SALE	28	2026-10-07 15:13:00	3
1442	16	16	SALE	31	2026-10-08 18:41:00	3
1443	16	16	SALE	31	2026-10-09 10:58:00	3
1444	16	16	SALE	50	2026-10-10 16:45:00	3
1445	16	16	SALE	53	2026-10-11 13:06:00	3
1446	16	16	SALE	26	2026-10-12 09:04:00	3
1447	16	16	SALE	36	2026-10-13 10:36:00	3
1448	16	16	SALE	41	2026-10-14 20:16:00	3
1449	16	16	SALE	29	2026-10-15 16:01:00	3
1450	16	16	SALE	31	2026-10-16 16:09:00	3
1451	16	16	SALE	49	2026-10-17 19:40:00	3
1452	16	16	SALE	32	2026-10-18 09:59:00	3
1453	16	16	SALE	26	2026-10-19 09:42:00	3
1454	16	16	SALE	23	2026-10-20 15:17:00	3
1455	16	16	SALE	32	2026-10-21 11:44:00	3
1456	16	16	SALE	29	2026-10-22 14:57:00	3
1457	17	17	RECEIPT	4675	2026-07-25 08:00:00	2
1458	17	17	SALE	66	2026-07-25 10:26:00	3
1459	17	17	SALE	55	2026-07-26 17:31:00	3
1460	17	17	SALE	37	2026-07-27 12:37:00	3
1461	17	17	SALE	25	2026-07-28 16:53:00	3
1462	17	17	SALE	30	2026-07-29 16:17:00	3
1463	17	17	SALE	47	2026-07-30 09:46:00	3
1464	17	17	SALE	15	2026-07-31 15:47:00	3
1465	17	17	SALE	48	2026-08-01 12:15:00	3
1466	17	17	SALE	54	2026-08-02 14:27:00	3
1467	17	17	SALE	33	2026-08-03 18:14:00	3
1468	17	17	SALE	46	2026-08-04 18:09:00	3
1469	17	17	SALE	28	2026-08-05 18:57:00	3
1470	17	17	SALE	20	2026-08-06 09:26:00	3
1471	17	17	SALE	32	2026-08-07 09:02:00	3
1472	17	17	SALE	63	2026-08-08 16:46:00	3
1473	17	17	SALE	65	2026-08-09 17:02:00	3
1474	17	17	SALE	40	2026-08-10 15:33:00	3
1475	17	17	SALE	41	2026-08-11 15:30:00	3
1476	17	17	SALE	40	2026-08-12 20:52:00	3
1477	17	17	SALE	47	2026-08-13 10:28:00	3
1478	17	17	SALE	19	2026-08-14 16:15:00	3
1479	17	17	SALE	136	2026-08-15 10:35:00	3
1480	17	17	SALE	52	2026-08-16 09:44:00	3
1481	17	17	SALE	31	2026-08-17 20:26:00	3
1482	17	17	SALE	21	2026-08-18 12:08:00	3
1483	17	17	SALE	36	2026-08-19 14:18:00	3
1484	17	17	SALE	39	2026-08-20 12:41:00	3
1485	17	17	SALE	33	2026-08-21 10:01:00	3
1486	17	17	SALE	71	2026-08-22 16:42:00	3
1487	17	17	SALE	55	2026-08-23 13:10:00	3
1488	17	17	SALE	50	2026-08-24 20:29:00	3
1489	17	17	SALE	40	2026-08-25 18:47:00	3
1490	17	17	SALE	48	2026-08-26 18:01:00	3
1491	17	17	SALE	45	2026-08-27 16:29:00	3
1492	17	17	SALE	41	2026-08-28 11:55:00	3
1493	17	17	SALE	52	2026-08-29 20:25:00	3
1494	17	17	SALE	45	2026-08-30 11:50:00	3
1495	17	17	SALE	52	2026-08-31 14:40:00	3
1496	17	17	SALE	48	2026-09-01 16:45:00	3
1497	17	17	SALE	47	2026-09-02 19:00:00	3
1498	17	17	SALE	44	2026-09-03 19:04:00	3
1499	17	17	SALE	38	2026-09-04 15:57:00	3
1500	17	17	SALE	49	2026-09-05 20:21:00	3
1501	17	17	SALE	67	2026-09-06 17:02:00	3
1502	17	17	SALE	39	2026-09-07 13:27:00	3
1503	17	17	SALE	49	2026-09-08 13:44:00	3
1504	17	17	SALE	34	2026-09-09 18:34:00	3
1505	17	17	SALE	33	2026-09-10 18:50:00	3
1506	17	17	SALE	40	2026-09-11 12:50:00	3
1507	17	17	SALE	57	2026-09-12 19:05:00	3
1508	17	17	SALE	48	2026-09-13 18:56:00	3
1509	17	17	SALE	26	2026-09-14 14:47:00	3
1510	17	17	SALE	43	2026-09-15 09:32:00	3
1511	17	17	SALE	44	2026-09-16 19:23:00	3
1512	17	17	SALE	44	2026-09-17 09:07:00	3
1513	17	17	SALE	50	2026-09-18 15:23:00	3
1514	17	17	SALE	68	2026-09-19 16:39:00	3
1515	17	17	SALE	62	2026-09-20 09:23:00	3
1516	17	17	SALE	47	2026-09-21 14:11:00	3
1517	17	17	SALE	60	2026-09-22 19:35:00	3
1518	17	17	SALE	54	2026-09-23 20:04:00	3
1519	17	17	SALE	22	2026-09-24 17:45:00	3
1520	17	17	SALE	35	2026-09-25 12:08:00	3
1521	17	17	SALE	48	2026-09-26 14:15:00	3
1522	17	17	SALE	65	2026-09-27 17:07:00	3
1523	17	17	SALE	34	2026-09-28 19:30:00	3
1524	17	17	SALE	46	2026-09-29 20:48:00	3
1525	17	17	SALE	41	2026-09-30 18:55:00	3
1526	17	17	SALE	27	2026-10-01 20:13:00	3
1527	17	17	SALE	28	2026-10-02 20:48:00	3
1528	17	17	SALE	47	2026-10-03 12:20:00	3
1529	17	17	SALE	54	2026-10-04 14:57:00	3
1530	17	17	SALE	40	2026-10-05 13:32:00	3
1531	17	17	SALE	47	2026-10-06 19:27:00	3
1532	17	17	SALE	39	2026-10-07 13:03:00	3
1533	17	17	SALE	22	2026-10-08 10:23:00	3
1534	17	17	SALE	40	2026-10-09 14:28:00	3
1535	17	17	SALE	58	2026-10-10 16:32:00	3
1536	17	17	SALE	49	2026-10-11 17:53:00	3
1537	17	17	SALE	38	2026-10-12 10:30:00	3
1538	17	17	SALE	35	2026-10-13 20:34:00	3
1539	17	17	SALE	36	2026-10-14 19:52:00	3
1540	17	17	SALE	42	2026-10-15 17:57:00	3
1541	17	17	SALE	46	2026-10-16 13:28:00	3
1542	17	17	SALE	45	2026-10-17 18:23:00	3
1543	17	17	SALE	52	2026-10-18 19:44:00	3
1544	17	17	SALE	39	2026-10-19 10:12:00	3
1545	17	17	SALE	34	2026-10-20 16:05:00	3
1546	17	17	SALE	44	2026-10-21 10:25:00	3
1547	17	17	SALE	20	2026-10-22 11:18:00	3
1548	18	18	RECEIPT	2190	2026-07-25 08:00:00	2
1549	18	18	SALE	29	2026-07-25 10:34:00	3
1550	18	18	SALE	25	2026-07-26 18:22:00	3
1551	18	18	SALE	21	2026-07-27 11:00:00	3
1552	18	18	SALE	27	2026-07-28 11:33:00	3
1553	18	18	SALE	15	2026-07-29 13:23:00	3
1554	18	18	SALE	10	2026-07-30 16:26:00	3
1555	18	18	SALE	18	2026-07-31 14:58:00	3
1556	18	18	SALE	23	2026-08-01 11:06:00	3
1557	18	18	SALE	23	2026-08-02 12:09:00	3
1558	18	18	SALE	18	2026-08-03 17:14:00	3
1559	18	18	SALE	19	2026-08-04 12:50:00	3
1560	18	18	SALE	14	2026-08-05 17:39:00	3
1561	18	18	SALE	14	2026-08-06 20:53:00	3
1562	18	18	SALE	17	2026-08-07 17:54:00	3
1563	18	18	SALE	25	2026-08-08 17:45:00	3
1564	18	18	SALE	22	2026-08-09 17:44:00	3
1565	18	18	SALE	20	2026-08-10 10:26:00	3
1566	18	18	SALE	20	2026-08-11 16:58:00	3
1567	18	18	SALE	20	2026-08-12 10:07:00	3
1568	18	18	SALE	22	2026-08-13 11:59:00	3
1569	18	18	SALE	16	2026-08-14 09:30:00	3
1570	18	18	SALE	16	2026-08-15 14:19:00	3
1571	18	18	SALE	24	2026-08-16 20:23:00	3
1572	18	18	SALE	16	2026-08-17 11:52:00	3
1573	18	18	SALE	17	2026-08-18 16:56:00	3
1574	18	18	SALE	13	2026-08-19 18:33:00	3
1575	18	18	SALE	9	2026-08-20 14:11:00	3
1576	18	18	SALE	21	2026-08-21 20:19:00	3
1577	18	18	SALE	29	2026-08-22 09:47:00	3
1578	18	18	SALE	24	2026-08-23 10:14:00	3
1579	18	18	SALE	22	2026-08-24 11:54:00	3
1580	18	18	SALE	17	2026-08-25 20:09:00	3
1581	18	18	SALE	16	2026-08-26 20:14:00	3
1582	18	18	SALE	25	2026-08-27 13:08:00	3
1583	18	18	SALE	23	2026-08-28 12:08:00	3
1584	18	18	SALE	26	2026-08-29 10:27:00	3
1585	18	18	SALE	28	2026-08-30 20:48:00	3
1586	18	18	SALE	21	2026-08-31 10:04:00	3
1587	18	18	SALE	19	2026-09-01 09:49:00	3
1588	18	18	SALE	19	2026-09-02 16:48:00	3
1589	18	18	SALE	16	2026-09-03 15:02:00	3
1590	18	18	SALE	20	2026-09-04 12:06:00	3
1591	18	18	SALE	26	2026-09-05 09:50:00	3
1592	18	18	SALE	18	2026-09-06 19:32:00	3
1593	18	18	SALE	14	2026-09-07 18:03:00	3
1594	18	18	SALE	10	2026-09-08 16:07:00	3
1595	18	18	SALE	13	2026-09-09 13:02:00	3
1596	18	18	SALE	18	2026-09-10 10:19:00	3
1597	18	18	SALE	16	2026-09-11 19:00:00	3
1598	18	18	SALE	22	2026-09-12 10:50:00	3
1599	18	18	SALE	22	2026-09-13 10:58:00	3
1600	18	18	SALE	21	2026-09-14 18:13:00	3
1601	18	18	SALE	20	2026-09-15 18:57:00	3
1602	18	18	SALE	25	2026-09-16 12:11:00	3
1603	18	18	SALE	16	2026-09-17 19:22:00	3
1604	18	18	SALE	19	2026-09-18 09:05:00	3
1605	18	18	SALE	20	2026-09-19 11:54:00	3
1606	18	18	SALE	27	2026-09-20 20:17:00	3
1607	18	18	SALE	22	2026-09-21 18:22:00	3
1608	18	18	SALE	18	2026-09-22 14:10:00	3
1609	18	18	SALE	40	2026-09-23 17:49:00	3
1610	18	18	SALE	16	2026-09-24 20:39:00	3
1611	18	18	SALE	20	2026-09-25 12:32:00	3
1612	18	18	SALE	30	2026-09-26 18:04:00	3
1613	18	18	SALE	25	2026-09-27 10:52:00	3
1614	18	18	SALE	22	2026-09-28 18:48:00	3
1615	18	18	SALE	14	2026-09-29 09:33:00	3
1616	18	18	SALE	16	2026-09-30 12:45:00	3
1617	18	18	SALE	19	2026-10-01 12:18:00	3
1618	18	18	SALE	16	2026-10-02 11:57:00	3
1619	18	18	SALE	29	2026-10-03 17:00:00	3
1620	18	18	SALE	28	2026-10-04 20:06:00	3
1621	18	18	SALE	17	2026-10-05 12:58:00	3
1622	18	18	SALE	17	2026-10-06 17:54:00	3
1623	18	18	SALE	23	2026-10-07 20:30:00	3
1624	18	18	SALE	17	2026-10-08 14:44:00	3
1625	18	18	SALE	15	2026-10-09 18:11:00	3
1626	18	18	SALE	28	2026-10-10 16:43:00	3
1627	18	18	SALE	25	2026-10-11 10:11:00	3
1628	18	18	SALE	17	2026-10-12 14:24:00	3
1629	18	18	SALE	20	2026-10-13 15:13:00	3
1630	18	18	SALE	21	2026-10-14 17:14:00	3
1631	18	18	SALE	21	2026-10-15 15:07:00	3
1632	18	18	SALE	19	2026-10-16 14:07:00	3
1633	18	18	SALE	22	2026-10-17 16:07:00	3
1634	18	18	SALE	29	2026-10-18 17:08:00	3
1635	18	18	SALE	18	2026-10-19 16:48:00	3
1636	18	18	SALE	13	2026-10-20 14:45:00	3
1637	18	18	SALE	15	2026-10-21 13:35:00	3
1638	18	18	SALE	24	2026-10-22 20:02:00	3
1639	19	19	RECEIPT	3742	2026-07-25 08:00:00	2
1640	19	19	SALE	34	2026-07-25 13:41:00	3
1641	19	19	SALE	44	2026-07-26 11:16:00	3
1642	19	19	SALE	32	2026-07-27 19:38:00	3
1643	19	19	SALE	26	2026-07-28 12:25:00	3
1644	19	19	SALE	19	2026-07-29 12:07:00	3
1645	19	19	SALE	35	2026-07-30 11:12:00	3
1646	19	19	SALE	94	2026-07-31 09:15:00	3
1647	19	19	SALE	41	2026-08-01 13:29:00	3
1648	19	19	SALE	41	2026-08-02 16:35:00	3
1649	19	19	SALE	27	2026-08-03 15:27:00	3
1650	19	19	SALE	40	2026-08-04 19:57:00	3
1651	19	19	SALE	29	2026-08-05 09:12:00	3
1652	19	19	SALE	27	2026-08-06 11:17:00	3
1653	19	19	SALE	33	2026-08-07 11:01:00	3
1654	19	19	SALE	42	2026-08-08 13:50:00	3
1655	19	19	SALE	50	2026-08-09 13:42:00	3
1656	19	19	SALE	22	2026-08-10 17:11:00	3
1657	19	19	SALE	24	2026-08-11 19:54:00	3
1658	19	19	SALE	25	2026-08-12 09:46:00	3
1659	19	19	SALE	37	2026-08-13 16:50:00	3
1660	19	19	SALE	27	2026-08-14 09:03:00	3
1661	19	19	SALE	39	2026-08-15 10:20:00	3
1662	19	19	SALE	42	2026-08-16 18:19:00	3
1663	19	19	SALE	29	2026-08-17 10:57:00	3
1664	19	19	SALE	29	2026-08-18 15:57:00	3
1665	19	19	SALE	30	2026-08-19 14:42:00	3
1666	19	19	SALE	28	2026-08-20 19:56:00	3
1667	19	19	SALE	35	2026-08-21 10:25:00	3
1668	19	19	SALE	36	2026-08-22 20:53:00	3
1669	19	19	SALE	40	2026-08-23 11:15:00	3
1670	19	19	SALE	23	2026-08-24 10:36:00	3
1671	19	19	SALE	30	2026-08-25 20:32:00	3
1672	19	19	SALE	40	2026-08-26 10:33:00	3
1673	19	19	SALE	31	2026-08-27 19:53:00	3
1674	19	19	SALE	35	2026-08-28 18:49:00	3
1675	19	19	SALE	46	2026-08-29 17:16:00	3
1676	19	19	SALE	34	2026-08-30 16:56:00	3
1677	19	19	SALE	21	2026-08-31 10:15:00	3
1678	19	19	SALE	25	2026-09-01 18:07:00	3
1679	19	19	SALE	32	2026-09-02 14:21:00	3
1680	19	19	SALE	24	2026-09-03 18:47:00	3
1681	19	19	SALE	27	2026-09-04 15:51:00	3
1682	19	19	SALE	39	2026-09-05 20:47:00	3
1683	19	19	SALE	39	2026-09-06 12:59:00	3
1684	19	19	SALE	24	2026-09-07 15:13:00	3
1685	19	19	SALE	36	2026-09-08 11:06:00	3
1686	19	19	SALE	37	2026-09-09 11:13:00	3
1687	19	19	SALE	33	2026-09-10 13:28:00	3
1688	19	19	SALE	33	2026-09-11 15:16:00	3
1689	19	19	SALE	35	2026-09-12 18:03:00	3
1690	19	19	SALE	48	2026-09-13 16:34:00	3
1691	19	19	SALE	30	2026-09-14 14:44:00	3
1692	19	19	SALE	31	2026-09-15 10:20:00	3
1693	19	19	SALE	35	2026-09-16 17:27:00	3
1694	19	19	SALE	32	2026-09-17 16:43:00	3
1695	19	19	SALE	28	2026-09-18 12:17:00	3
1696	19	19	SALE	36	2026-09-19 11:23:00	3
1697	19	19	SALE	36	2026-09-20 16:45:00	3
1698	19	19	SALE	29	2026-09-21 14:52:00	3
1699	19	19	SALE	30	2026-09-22 13:01:00	3
1700	19	19	SALE	29	2026-09-23 19:57:00	3
1701	19	19	SALE	32	2026-09-24 18:02:00	3
1702	19	19	SALE	32	2026-09-25 20:42:00	3
1703	19	19	SALE	50	2026-09-26 09:44:00	3
1704	19	19	SALE	45	2026-09-27 19:15:00	3
1705	19	19	SALE	29	2026-09-28 13:35:00	3
1706	19	19	SALE	40	2026-09-29 15:19:00	3
1707	19	19	SALE	35	2026-09-30 19:44:00	3
1708	19	19	SALE	28	2026-10-01 14:57:00	3
1709	19	19	SALE	37	2026-10-02 19:07:00	3
1710	19	19	SALE	43	2026-10-03 17:55:00	3
1711	19	19	SALE	33	2026-10-04 12:54:00	3
1712	19	19	SALE	24	2026-10-05 16:24:00	3
1713	19	19	SALE	29	2026-10-06 09:58:00	3
1714	19	19	SALE	33	2026-10-07 15:59:00	3
1715	19	19	SALE	24	2026-10-08 13:19:00	3
1716	19	19	SALE	28	2026-10-09 10:59:00	3
1717	19	19	SALE	48	2026-10-10 12:19:00	3
1718	19	19	SALE	48	2026-10-11 12:55:00	3
1719	19	19	SALE	24	2026-10-12 11:58:00	3
1720	19	19	SALE	21	2026-10-13 16:40:00	3
1721	19	19	SALE	30	2026-10-14 14:56:00	3
1722	19	19	SALE	29	2026-10-15 19:26:00	3
1723	19	19	SALE	38	2026-10-16 09:17:00	3
1724	19	19	SALE	53	2026-10-17 10:52:00	3
1725	19	19	SALE	36	2026-10-18 16:30:00	3
1726	19	19	SALE	31	2026-10-19 20:26:00	3
1727	19	19	SALE	40	2026-10-20 14:45:00	3
1728	19	19	SALE	20	2026-10-21 15:56:00	3
1729	19	19	SALE	36	2026-10-22 10:52:00	3
1730	20	20	RECEIPT	2650	2026-07-25 08:00:00	2
1731	20	20	SALE	28	2026-07-25 12:10:00	3
1732	20	20	SALE	32	2026-07-26 15:49:00	3
1733	20	20	SALE	18	2026-07-27 15:18:00	3
1734	20	20	SALE	27	2026-07-28 19:48:00	3
1735	20	20	SALE	23	2026-07-29 19:09:00	3
1736	20	20	SALE	55	2026-07-30 10:19:00	3
1737	20	20	SALE	19	2026-07-31 16:51:00	3
1738	20	20	SALE	34	2026-08-01 15:47:00	3
1739	20	20	SALE	29	2026-08-02 13:57:00	3
1740	20	20	SALE	19	2026-08-03 19:38:00	3
1741	20	20	SALE	25	2026-08-04 11:22:00	3
1742	20	20	SALE	19	2026-08-05 19:06:00	3
1743	20	20	SALE	24	2026-08-06 14:32:00	3
1744	20	20	SALE	26	2026-08-07 12:31:00	3
1745	20	20	SALE	25	2026-08-08 16:56:00	3
1746	20	20	SALE	34	2026-08-09 15:30:00	3
1747	20	20	SALE	22	2026-08-10 13:36:00	3
1748	20	20	SALE	21	2026-08-11 18:27:00	3
1749	20	20	SALE	21	2026-08-12 10:48:00	3
1750	20	20	SALE	23	2026-08-13 15:51:00	3
1751	20	20	SALE	22	2026-08-14 14:39:00	3
1752	20	20	SALE	29	2026-08-15 11:27:00	3
1753	20	20	SALE	86	2026-08-16 19:27:00	3
1754	20	20	SALE	26	2026-08-17 10:02:00	3
1755	20	20	SALE	28	2026-08-18 17:21:00	3
1756	20	20	SALE	18	2026-08-19 16:43:00	3
1757	20	20	SALE	24	2026-08-20 12:41:00	3
1758	20	20	SALE	31	2026-08-21 19:45:00	3
1759	20	20	SALE	27	2026-08-22 11:59:00	3
1760	20	20	SALE	31	2026-08-23 16:33:00	3
1761	20	20	SALE	21	2026-08-24 19:41:00	3
1762	20	20	SALE	18	2026-08-25 17:05:00	3
1763	20	20	SALE	32	2026-08-26 13:29:00	3
1764	20	20	SALE	23	2026-08-27 15:05:00	3
1765	20	20	SALE	21	2026-08-28 16:19:00	3
1766	20	20	SALE	33	2026-08-29 11:08:00	3
1767	20	20	SALE	35	2026-08-30 19:57:00	3
1768	20	20	SALE	20	2026-08-31 13:53:00	3
1769	20	20	SALE	16	2026-09-01 12:33:00	3
1770	20	20	SALE	24	2026-09-02 15:18:00	3
1771	20	20	SALE	30	2026-09-03 18:03:00	3
1772	20	20	SALE	24	2026-09-04 17:04:00	3
1773	20	20	SALE	26	2026-09-05 09:32:00	3
1774	20	20	SALE	60	2026-09-06 10:32:00	3
1775	20	20	SALE	13	2026-09-07 15:26:00	3
1776	20	20	SALE	29	2026-09-08 10:29:00	3
1777	20	20	SALE	22	2026-09-09 19:46:00	3
1778	20	20	SALE	20	2026-09-10 18:52:00	3
1779	20	20	SALE	17	2026-09-11 13:22:00	3
1780	20	20	SALE	28	2026-09-12 13:37:00	3
1781	20	20	SALE	29	2026-09-13 10:49:00	3
1782	20	20	SALE	25	2026-09-14 17:01:00	3
1783	20	20	SALE	24	2026-09-15 10:47:00	3
1784	20	20	SALE	20	2026-09-16 19:29:00	3
1785	20	20	SALE	24	2026-09-17 11:50:00	3
1786	20	20	SALE	19	2026-09-18 11:53:00	3
1787	20	20	SALE	27	2026-09-19 15:02:00	3
1788	20	20	SALE	30	2026-09-20 10:26:00	3
1789	20	20	SALE	12	2026-09-21 20:19:00	3
1790	20	20	SALE	18	2026-09-22 14:37:00	3
1791	20	20	SALE	22	2026-09-23 20:29:00	3
1792	20	20	SALE	22	2026-09-24 19:28:00	3
1793	20	20	SALE	23	2026-09-25 18:51:00	3
1794	20	20	SALE	35	2026-09-26 13:21:00	3
1795	20	20	SALE	35	2026-09-27 11:13:00	3
1796	20	20	SALE	21	2026-09-28 11:05:00	3
1797	20	20	SALE	21	2026-09-29 20:38:00	3
1798	20	20	SALE	19	2026-09-30 13:55:00	3
1799	20	20	SALE	19	2026-10-01 19:06:00	3
1800	20	20	SALE	29	2026-10-02 15:34:00	3
1801	20	20	SALE	28	2026-10-03 09:00:00	3
1802	20	20	SALE	25	2026-10-04 15:07:00	3
1803	20	20	SALE	25	2026-10-05 09:10:00	3
1804	20	20	SALE	30	2026-10-06 19:30:00	3
1805	20	20	SALE	24	2026-10-07 16:44:00	3
1806	20	20	SALE	23	2026-10-08 15:55:00	3
1807	20	20	SALE	24	2026-10-09 19:47:00	3
1808	20	20	SALE	31	2026-10-10 18:46:00	3
1809	20	20	SALE	21	2026-10-11 16:19:00	3
1810	20	20	SALE	23	2026-10-12 18:52:00	3
1811	20	20	SALE	20	2026-10-13 18:23:00	3
1812	20	20	SALE	27	2026-10-14 20:43:00	3
1813	20	20	SALE	18	2026-10-15 20:43:00	3
1814	20	20	SALE	18	2026-10-16 15:51:00	3
1815	20	20	SALE	32	2026-10-17 13:05:00	3
1816	20	20	SALE	29	2026-10-18 11:08:00	3
1817	20	20	SALE	23	2026-10-19 09:12:00	3
1818	20	20	SALE	14	2026-10-20 10:52:00	3
1819	20	20	SALE	24	2026-10-21 09:44:00	3
1820	20	20	SALE	23	2026-10-22 12:54:00	3
1821	21	21	RECEIPT	2465	2026-07-25 08:00:00	2
1822	21	21	SALE	26	2026-07-25 09:01:00	3
1823	21	21	SALE	33	2026-07-26 17:37:00	3
1824	21	21	SALE	20	2026-07-27 13:15:00	3
1825	21	21	SALE	22	2026-07-28 13:46:00	3
1826	21	21	SALE	20	2026-07-29 15:32:00	3
1827	21	21	SALE	23	2026-07-30 10:46:00	3
1828	21	21	SALE	42	2026-07-31 09:53:00	3
1829	21	21	SALE	31	2026-08-01 14:16:00	3
1830	21	21	SALE	29	2026-08-02 19:32:00	3
1831	21	21	SALE	24	2026-08-03 14:07:00	3
1832	21	21	SALE	18	2026-08-04 09:48:00	3
1833	21	21	SALE	24	2026-08-05 19:07:00	3
1834	21	21	SALE	20	2026-08-06 16:19:00	3
1835	21	21	SALE	6	2026-08-07 18:47:00	3
1836	21	21	SALE	29	2026-08-08 09:29:00	3
1837	21	21	SALE	22	2026-08-09 14:15:00	3
1838	21	21	SALE	23	2026-08-10 20:37:00	3
1839	21	21	SALE	22	2026-08-11 18:45:00	3
1840	21	21	SALE	21	2026-08-12 19:42:00	3
1841	21	21	SALE	28	2026-08-13 17:54:00	3
1842	21	21	SALE	17	2026-08-14 18:14:00	3
1843	21	21	SALE	26	2026-08-15 14:19:00	3
1844	21	21	SALE	27	2026-08-16 13:42:00	3
1845	21	21	SALE	23	2026-08-17 20:36:00	3
1846	21	21	SALE	18	2026-08-18 19:08:00	3
1847	21	21	SALE	13	2026-08-19 20:24:00	3
1848	21	21	SALE	13	2026-08-20 17:47:00	3
1849	21	21	SALE	24	2026-08-21 12:06:00	3
1850	21	21	SALE	36	2026-08-22 14:33:00	3
1851	21	21	SALE	28	2026-08-23 18:12:00	3
1852	21	21	SALE	24	2026-08-24 14:29:00	3
1853	21	21	SALE	25	2026-08-25 10:09:00	3
1854	21	21	SALE	19	2026-08-26 20:27:00	3
1855	21	21	SALE	22	2026-08-27 15:05:00	3
1856	21	21	SALE	25	2026-08-28 10:03:00	3
1857	21	21	SALE	19	2026-08-29 15:56:00	3
1858	21	21	SALE	31	2026-08-30 11:30:00	3
1859	21	21	SALE	25	2026-08-31 12:28:00	3
1860	21	21	SALE	25	2026-09-01 10:23:00	3
1861	21	21	SALE	18	2026-09-02 19:33:00	3
1862	21	21	SALE	24	2026-09-03 15:37:00	3
1863	21	21	SALE	24	2026-09-04 17:33:00	3
1864	21	21	SALE	35	2026-09-05 15:55:00	3
1865	21	21	SALE	24	2026-09-06 13:37:00	3
1866	21	21	SALE	27	2026-09-07 16:40:00	3
1867	21	21	SALE	15	2026-09-08 15:28:00	3
1868	21	21	SALE	32	2026-09-09 20:59:00	3
1869	21	21	SALE	25	2026-09-10 16:46:00	3
1870	21	21	SALE	22	2026-09-11 15:52:00	3
1871	21	21	SALE	19	2026-09-12 11:09:00	3
1872	21	21	SALE	24	2026-09-13 17:08:00	3
1873	21	21	SALE	20	2026-09-14 16:45:00	3
1874	21	21	SALE	23	2026-09-15 16:08:00	3
1875	21	21	SALE	26	2026-09-16 20:32:00	3
1876	21	21	SALE	22	2026-09-17 17:07:00	3
1877	21	21	SALE	17	2026-09-18 20:13:00	3
1878	21	21	SALE	31	2026-09-19 16:30:00	3
1879	21	21	SALE	31	2026-09-20 09:47:00	3
1880	21	21	SALE	30	2026-09-21 11:35:00	3
1881	21	21	SALE	22	2026-09-22 14:58:00	3
1882	21	21	SALE	24	2026-09-23 10:38:00	3
1883	21	21	SALE	25	2026-09-24 15:07:00	3
1884	21	21	SALE	20	2026-09-25 10:23:00	3
1885	21	21	SALE	29	2026-09-26 18:18:00	3
1886	21	21	SALE	20	2026-09-27 09:33:00	3
1887	21	21	SALE	26	2026-09-28 11:07:00	3
1888	21	21	SALE	15	2026-09-29 14:19:00	3
1889	21	21	SALE	21	2026-09-30 14:19:00	3
1890	21	21	SALE	23	2026-10-01 13:31:00	3
1891	21	21	SALE	15	2026-10-02 09:50:00	3
1892	21	21	SALE	24	2026-10-03 11:09:00	3
1893	21	21	SALE	35	2026-10-04 18:26:00	3
1894	21	21	SALE	24	2026-10-05 09:59:00	3
1895	21	21	SALE	21	2026-10-06 13:56:00	3
1896	21	21	SALE	30	2026-10-07 13:13:00	3
1897	21	21	SALE	21	2026-10-08 11:52:00	3
1898	21	21	SALE	14	2026-10-09 20:31:00	3
1899	21	21	SALE	37	2026-10-10 09:07:00	3
1900	21	21	SALE	25	2026-10-11 17:22:00	3
1901	21	21	SALE	29	2026-10-12 10:55:00	3
1902	21	21	SALE	25	2026-10-13 09:26:00	3
1903	21	21	SALE	26	2026-10-14 16:36:00	3
1904	21	21	SALE	18	2026-10-15 13:36:00	3
1905	21	21	SALE	18	2026-10-16 16:57:00	3
1906	21	21	SALE	28	2026-10-17 14:50:00	3
1907	21	21	SALE	23	2026-10-18 15:30:00	3
1908	21	21	SALE	17	2026-10-19 20:53:00	3
1909	21	21	SALE	26	2026-10-20 18:08:00	3
1910	21	21	SALE	19	2026-10-21 11:32:00	3
1911	21	21	SALE	21	2026-10-22 19:29:00	3
1912	22	22	RECEIPT	2883	2026-07-25 08:00:00	2
1913	22	22	SALE	31	2026-07-25 19:35:00	3
1914	22	22	SALE	27	2026-07-26 16:00:00	3
1915	22	22	SALE	19	2026-07-27 15:41:00	3
1916	22	22	SALE	19	2026-07-28 19:41:00	3
1917	22	22	SALE	28	2026-07-29 09:54:00	3
1918	22	22	SALE	24	2026-07-30 14:27:00	3
1919	22	22	SALE	24	2026-07-31 15:17:00	3
1920	22	22	SALE	33	2026-08-01 10:43:00	3
1921	22	22	SALE	26	2026-08-02 17:29:00	3
1922	22	22	SALE	17	2026-08-03 16:23:00	3
1923	22	22	SALE	15	2026-08-04 17:48:00	3
1924	22	22	SALE	20	2026-08-05 09:56:00	3
1925	22	22	SALE	58	2026-08-06 20:14:00	3
1926	22	22	SALE	17	2026-08-07 09:17:00	3
1927	22	22	SALE	32	2026-08-08 15:34:00	3
1928	22	22	SALE	35	2026-08-09 16:20:00	3
1929	22	22	SALE	27	2026-08-10 09:25:00	3
1930	22	22	SALE	25	2026-08-11 12:21:00	3
1931	22	22	SALE	12	2026-08-12 10:56:00	3
1932	22	22	SALE	23	2026-08-13 18:51:00	3
1933	22	22	SALE	27	2026-08-14 09:47:00	3
1934	22	22	SALE	30	2026-08-15 12:44:00	3
1935	22	22	SALE	30	2026-08-16 15:04:00	3
1936	22	22	SALE	25	2026-08-17 12:12:00	3
1937	22	22	SALE	28	2026-08-18 11:21:00	3
1938	22	22	SALE	20	2026-08-19 13:04:00	3
1939	22	22	SALE	25	2026-08-20 19:40:00	3
1940	22	22	SALE	28	2026-08-21 10:01:00	3
1941	22	22	SALE	32	2026-08-22 16:27:00	3
1942	22	22	SALE	30	2026-08-23 09:37:00	3
1943	22	22	SALE	22	2026-08-24 19:59:00	3
1944	22	22	SALE	28	2026-08-25 14:53:00	3
1945	22	22	SALE	11	2026-08-26 13:15:00	3
1946	22	22	SALE	22	2026-08-27 10:30:00	3
1947	22	22	SALE	20	2026-08-28 12:21:00	3
1948	22	22	SALE	31	2026-08-29 09:52:00	3
1949	22	22	SALE	23	2026-08-30 14:33:00	3
1950	22	22	SALE	20	2026-08-31 12:04:00	3
1951	22	22	SALE	21	2026-09-01 18:39:00	3
1952	22	22	SALE	20	2026-09-02 16:48:00	3
1953	22	22	SALE	25	2026-09-03 10:40:00	3
1954	22	22	SALE	18	2026-09-04 16:37:00	3
1955	22	22	SALE	33	2026-09-05 10:05:00	3
1956	22	22	SALE	36	2026-09-06 09:58:00	3
1957	22	22	SALE	30	2026-09-07 09:24:00	3
1958	22	22	SALE	24	2026-09-08 14:56:00	3
1959	22	22	SALE	20	2026-09-09 20:04:00	3
1960	22	22	SALE	20	2026-09-10 11:03:00	3
1961	22	22	SALE	22	2026-09-11 16:03:00	3
1962	22	22	SALE	36	2026-09-12 13:39:00	3
1963	22	22	SALE	31	2026-09-13 19:27:00	3
1964	22	22	SALE	19	2026-09-14 10:06:00	3
1965	22	22	SALE	24	2026-09-15 19:03:00	3
1966	22	22	SALE	23	2026-09-16 17:03:00	3
1967	22	22	SALE	19	2026-09-17 13:54:00	3
1968	22	22	SALE	6	2026-09-18 15:25:00	3
1969	22	22	SALE	34	2026-09-19 10:39:00	3
1970	22	22	SALE	23	2026-09-20 15:14:00	3
1971	22	22	SALE	21	2026-09-21 18:50:00	3
1972	22	22	SALE	19	2026-09-22 19:39:00	3
1973	22	22	SALE	25	2026-09-23 09:29:00	3
1974	22	22	SALE	33	2026-09-24 15:29:00	3
1975	22	22	SALE	29	2026-09-25 15:56:00	3
1976	22	22	SALE	78	2026-09-26 18:39:00	3
1977	22	22	SALE	29	2026-09-27 10:21:00	3
1978	22	22	SALE	17	2026-09-28 19:43:00	3
1979	22	22	SALE	27	2026-09-29 09:29:00	3
1980	22	22	SALE	18	2026-09-30 17:21:00	3
1981	22	22	SALE	24	2026-10-01 18:12:00	3
1982	22	22	SALE	18	2026-10-02 10:06:00	3
1983	22	22	SALE	27	2026-10-03 09:38:00	3
1984	22	22	SALE	30	2026-10-04 20:04:00	3
1985	22	22	SALE	25	2026-10-05 18:50:00	3
1986	22	22	SALE	69	2026-10-06 12:57:00	3
1987	22	22	SALE	22	2026-10-07 18:08:00	3
1988	22	22	SALE	15	2026-10-08 19:32:00	3
1989	22	22	SALE	24	2026-10-09 13:22:00	3
1990	22	22	SALE	24	2026-10-10 15:30:00	3
1991	22	22	SALE	38	2026-10-11 20:39:00	3
1992	22	22	SALE	23	2026-10-12 16:11:00	3
1993	22	22	SALE	35	2026-10-13 12:08:00	3
1994	22	22	SALE	23	2026-10-14 09:03:00	3
1995	22	22	SALE	21	2026-10-15 11:19:00	3
1996	22	22	SALE	27	2026-10-16 18:27:00	3
1997	22	22	SALE	29	2026-10-17 17:41:00	3
1998	22	22	SALE	26	2026-10-18 14:19:00	3
1999	22	22	SALE	29	2026-10-19 18:56:00	3
2000	22	22	SALE	29	2026-10-20 17:49:00	3
2001	22	22	SALE	22	2026-10-21 11:09:00	3
2002	22	22	SALE	19	2026-10-22 16:19:00	3
2003	23	23	RECEIPT	2590	2026-07-25 08:00:00	2
2004	23	23	SALE	27	2026-07-25 14:37:00	3
2005	23	23	SALE	41	2026-07-26 09:36:00	3
2006	23	23	SALE	22	2026-07-27 09:59:00	3
2007	23	23	SALE	29	2026-07-28 11:09:00	3
2008	23	23	SALE	15	2026-07-29 14:36:00	3
2009	23	23	SALE	31	2026-07-30 19:51:00	3
2010	23	23	SALE	23	2026-07-31 18:58:00	3
2011	23	23	SALE	31	2026-08-01 18:36:00	3
2012	23	23	SALE	33	2026-08-02 15:24:00	3
2013	23	23	SALE	17	2026-08-03 12:25:00	3
2014	23	23	SALE	20	2026-08-04 10:34:00	3
2015	23	23	SALE	23	2026-08-05 15:12:00	3
2016	23	23	SALE	12	2026-08-06 16:06:00	3
2017	23	23	SALE	21	2026-08-07 14:36:00	3
2018	23	23	SALE	30	2026-08-08 16:40:00	3
2019	23	23	SALE	35	2026-08-09 13:05:00	3
2020	23	23	SALE	18	2026-08-10 11:06:00	3
2021	23	23	SALE	48	2026-08-11 19:35:00	3
2022	23	23	SALE	18	2026-08-12 11:02:00	3
2023	23	23	SALE	25	2026-08-13 20:38:00	3
2024	23	23	SALE	15	2026-08-14 16:01:00	3
2025	23	23	SALE	25	2026-08-15 11:12:00	3
2026	23	23	SALE	29	2026-08-16 10:58:00	3
2027	23	23	SALE	24	2026-08-17 15:18:00	3
2028	23	23	SALE	21	2026-08-18 12:14:00	3
2029	23	23	SALE	24	2026-08-19 13:42:00	3
2030	23	23	SALE	27	2026-08-20 17:04:00	3
2031	23	23	SALE	26	2026-08-21 16:03:00	3
2032	23	23	SALE	29	2026-08-22 14:33:00	3
2033	23	23	SALE	31	2026-08-23 09:10:00	3
2034	23	23	SALE	23	2026-08-24 14:55:00	3
2035	23	23	SALE	26	2026-08-25 15:25:00	3
2036	23	23	SALE	15	2026-08-26 11:07:00	3
2037	23	23	SALE	24	2026-08-27 11:34:00	3
2038	23	23	SALE	23	2026-08-28 15:30:00	3
2039	23	23	SALE	32	2026-08-29 20:04:00	3
2040	23	23	SALE	23	2026-08-30 15:57:00	3
2041	23	23	SALE	14	2026-08-31 12:08:00	3
2042	23	23	SALE	23	2026-09-01 12:19:00	3
2043	23	23	SALE	18	2026-09-02 15:52:00	3
2044	23	23	SALE	19	2026-09-03 20:42:00	3
2045	23	23	SALE	19	2026-09-04 16:10:00	3
2046	23	23	SALE	23	2026-09-05 18:36:00	3
2047	23	23	SALE	31	2026-09-06 13:37:00	3
2048	23	23	SALE	23	2026-09-07 12:32:00	3
2049	23	23	SALE	25	2026-09-08 20:43:00	3
2050	23	23	SALE	17	2026-09-09 16:17:00	3
2051	23	23	SALE	25	2026-09-10 12:00:00	3
2052	23	23	SALE	16	2026-09-11 11:28:00	3
2053	23	23	SALE	29	2026-09-12 10:52:00	3
2054	23	23	SALE	32	2026-09-13 15:38:00	3
2055	23	23	SALE	15	2026-09-14 12:33:00	3
2056	23	23	SALE	18	2026-09-15 14:58:00	3
2057	23	23	SALE	22	2026-09-16 18:56:00	3
2058	23	23	SALE	19	2026-09-17 16:29:00	3
2059	23	23	SALE	23	2026-09-18 16:36:00	3
2060	23	23	SALE	28	2026-09-19 09:47:00	3
2061	23	23	SALE	25	2026-09-20 10:18:00	3
2062	23	23	SALE	17	2026-09-21 19:56:00	3
2063	23	23	SALE	21	2026-09-22 16:22:00	3
2064	23	23	SALE	18	2026-09-23 20:53:00	3
2065	23	23	SALE	25	2026-09-24 20:50:00	3
2066	23	23	SALE	18	2026-09-25 13:25:00	3
2067	23	23	SALE	32	2026-09-26 18:52:00	3
2068	23	23	SALE	28	2026-09-27 11:26:00	3
2069	23	23	SALE	21	2026-09-28 12:11:00	3
2070	23	23	SALE	24	2026-09-29 18:46:00	3
2071	23	23	SALE	24	2026-09-30 15:29:00	3
2072	23	23	SALE	20	2026-10-01 15:58:00	3
2073	23	23	SALE	18	2026-10-02 19:11:00	3
2074	23	23	SALE	33	2026-10-03 20:36:00	3
2075	23	23	SALE	36	2026-10-04 10:25:00	3
2076	23	23	SALE	18	2026-10-05 20:02:00	3
2077	23	23	SALE	20	2026-10-06 12:56:00	3
2078	23	23	SALE	13	2026-10-07 11:17:00	3
2079	23	23	SALE	33	2026-10-08 19:34:00	3
2080	23	23	SALE	21	2026-10-09 13:42:00	3
2081	23	23	SALE	31	2026-10-10 10:44:00	3
2082	23	23	SALE	32	2026-10-11 20:46:00	3
2083	23	23	SALE	28	2026-10-12 12:58:00	3
2084	23	23	SALE	16	2026-10-13 16:26:00	3
2085	23	23	SALE	18	2026-10-14 17:07:00	3
2086	23	23	SALE	20	2026-10-15 14:04:00	3
2087	23	23	SALE	22	2026-10-16 10:32:00	3
2088	23	23	SALE	27	2026-10-17 14:26:00	3
2089	23	23	SALE	30	2026-10-18 16:10:00	3
2090	23	23	SALE	24	2026-10-19 13:13:00	3
2091	23	23	SALE	18	2026-10-20 17:02:00	3
2092	23	23	SALE	19	2026-10-21 16:01:00	3
2093	23	23	SALE	18	2026-10-22 10:40:00	3
2094	24	24	RECEIPT	3566	2026-07-25 08:00:00	2
2095	24	24	SALE	40	2026-07-25 20:23:00	3
2096	24	24	SALE	36	2026-07-26 15:31:00	3
2097	24	24	SALE	31	2026-07-27 13:41:00	3
2098	24	24	SALE	28	2026-07-28 18:04:00	3
2099	24	24	SALE	28	2026-07-29 15:56:00	3
2100	24	24	SALE	22	2026-07-30 09:58:00	3
2101	24	24	SALE	29	2026-07-31 10:24:00	3
2102	24	24	SALE	55	2026-08-01 18:10:00	3
2103	24	24	SALE	40	2026-08-02 12:48:00	3
2104	24	24	SALE	28	2026-08-03 15:16:00	3
2105	24	24	SALE	26	2026-08-04 20:22:00	3
2106	24	24	SALE	29	2026-08-05 17:45:00	3
2107	24	24	SALE	31	2026-08-06 16:40:00	3
2108	24	24	SALE	32	2026-08-07 20:23:00	3
2109	24	24	SALE	42	2026-08-08 20:03:00	3
2110	24	24	SALE	49	2026-08-09 19:24:00	3
2111	24	24	SALE	25	2026-08-10 15:47:00	3
2112	24	24	SALE	16	2026-08-11 12:15:00	3
2113	24	24	SALE	29	2026-08-12 16:02:00	3
2114	24	24	SALE	28	2026-08-13 14:40:00	3
2115	24	24	SALE	33	2026-08-14 20:43:00	3
2116	24	24	SALE	35	2026-08-15 09:44:00	3
2117	24	24	SALE	40	2026-08-16 19:41:00	3
2118	24	24	SALE	31	2026-08-17 11:16:00	3
2119	24	24	SALE	35	2026-08-18 18:29:00	3
2120	24	24	SALE	21	2026-08-19 19:09:00	3
2121	24	24	SALE	31	2026-08-20 13:15:00	3
2122	24	24	SALE	33	2026-08-21 18:37:00	3
2123	24	24	SALE	41	2026-08-22 19:53:00	3
2124	24	24	SALE	45	2026-08-23 11:00:00	3
2125	24	24	SALE	29	2026-08-24 10:49:00	3
2126	24	24	SALE	33	2026-08-25 10:41:00	3
2127	24	24	SALE	26	2026-08-26 20:58:00	3
2128	24	24	SALE	33	2026-08-27 15:25:00	3
2129	24	24	SALE	31	2026-08-28 20:37:00	3
2130	24	24	SALE	29	2026-08-29 10:33:00	3
2131	24	24	SALE	25	2026-08-30 12:56:00	3
2132	24	24	SALE	19	2026-08-31 15:10:00	3
2133	24	24	SALE	39	2026-09-01 15:16:00	3
2134	24	24	SALE	27	2026-09-02 20:19:00	3
2135	24	24	SALE	15	2026-09-03 17:34:00	3
2136	24	24	SALE	19	2026-09-04 19:56:00	3
2137	24	24	SALE	40	2026-09-05 15:37:00	3
2138	24	24	SALE	37	2026-09-06 13:46:00	3
2139	24	24	SALE	32	2026-09-07 15:48:00	3
2140	24	24	SALE	23	2026-09-08 20:55:00	3
2141	24	24	SALE	23	2026-09-09 10:06:00	3
2142	24	24	SALE	25	2026-09-10 19:36:00	3
2143	24	24	SALE	14	2026-09-11 14:52:00	3
2144	24	24	SALE	31	2026-09-12 11:17:00	3
2145	24	24	SALE	37	2026-09-13 20:13:00	3
2146	24	24	SALE	19	2026-09-14 20:25:00	3
2147	24	24	SALE	25	2026-09-15 20:19:00	3
2148	24	24	SALE	31	2026-09-16 09:10:00	3
2149	24	24	SALE	40	2026-09-17 16:00:00	3
2150	24	24	SALE	31	2026-09-18 10:04:00	3
2151	24	24	SALE	38	2026-09-19 20:26:00	3
2152	24	24	SALE	45	2026-09-20 17:26:00	3
2153	24	24	SALE	36	2026-09-21 19:18:00	3
2154	24	24	SALE	27	2026-09-22 20:27:00	3
2155	24	24	SALE	31	2026-09-23 11:11:00	3
2156	24	24	SALE	24	2026-09-24 14:11:00	3
2157	24	24	SALE	35	2026-09-25 20:08:00	3
2158	24	24	SALE	36	2026-09-26 12:31:00	3
2159	24	24	SALE	36	2026-09-27 11:32:00	3
2160	24	24	SALE	89	2026-09-28 10:28:00	3
2161	24	24	SALE	31	2026-09-29 18:52:00	3
2162	24	24	SALE	30	2026-09-30 12:11:00	3
2163	24	24	SALE	29	2026-10-01 12:03:00	3
2164	24	24	SALE	30	2026-10-02 20:11:00	3
2165	24	24	SALE	42	2026-10-03 12:16:00	3
2166	24	24	SALE	40	2026-10-04 15:28:00	3
2167	24	24	SALE	28	2026-10-05 19:58:00	3
2168	24	24	SALE	31	2026-10-06 18:06:00	3
2169	24	24	SALE	20	2026-10-07 19:10:00	3
2170	24	24	SALE	31	2026-10-08 10:18:00	3
2171	24	24	SALE	41	2026-10-09 10:24:00	3
2172	24	24	SALE	45	2026-10-10 10:17:00	3
2173	24	24	SALE	38	2026-10-11 10:21:00	3
2174	24	24	SALE	19	2026-10-12 09:37:00	3
2175	24	24	SALE	33	2026-10-13 12:30:00	3
2176	24	24	SALE	29	2026-10-14 16:43:00	3
2177	24	24	SALE	35	2026-10-15 10:00:00	3
2178	24	24	SALE	24	2026-10-16 09:17:00	3
2179	24	24	SALE	32	2026-10-17 09:42:00	3
2180	24	24	SALE	41	2026-10-18 18:50:00	3
2181	24	24	SALE	32	2026-10-19 09:06:00	3
2182	24	24	SALE	33	2026-10-20 12:33:00	3
2183	24	24	SALE	35	2026-10-21 09:24:00	3
2184	24	24	SALE	29	2026-10-22 18:33:00	3
2185	25	25	RECEIPT	930	2026-07-25 08:00:00	2
2186	25	25	SALE	14	2026-07-25 09:07:00	3
2187	25	25	SALE	8	2026-07-26 17:41:00	3
2188	25	25	SALE	6	2026-07-27 14:37:00	3
2189	25	25	SALE	12	2026-07-28 15:09:00	3
2190	25	25	SALE	11	2026-07-29 19:46:00	3
2191	25	25	SALE	8	2026-07-30 15:15:00	3
2192	25	25	SALE	8	2026-07-31 09:07:00	3
2193	25	25	SALE	14	2026-08-01 12:25:00	3
2194	25	25	SALE	14	2026-08-02 16:19:00	3
2195	25	25	SALE	8	2026-08-03 20:38:00	3
2196	25	25	SALE	8	2026-08-04 11:41:00	3
2197	25	25	SALE	12	2026-08-05 20:24:00	3
2198	25	25	SALE	7	2026-08-06 20:50:00	3
2199	25	25	SALE	7	2026-08-07 19:42:00	3
2200	25	25	SALE	17	2026-08-08 10:49:00	3
2201	25	25	SALE	11	2026-08-09 16:55:00	3
2202	25	25	SALE	12	2026-08-10 19:24:00	3
2203	25	25	SALE	10	2026-08-11 13:40:00	3
2204	25	25	SALE	8	2026-08-12 19:28:00	3
2205	25	25	SALE	8	2026-08-13 14:00:00	3
2206	25	25	SALE	5	2026-08-14 10:07:00	3
2207	25	25	SALE	15	2026-08-15 10:07:00	3
2208	25	25	SALE	13	2026-08-16 16:41:00	3
2209	25	25	SALE	8	2026-08-17 19:58:00	3
2210	25	25	SALE	7	2026-08-18 17:14:00	3
2211	25	25	SALE	9	2026-08-19 09:37:00	3
2212	25	25	SALE	11	2026-08-20 18:36:00	3
2213	25	25	SALE	11	2026-08-21 16:17:00	3
2214	25	25	SALE	13	2026-08-22 20:47:00	3
2215	25	25	SALE	11	2026-08-23 10:50:00	3
2216	25	25	SALE	9	2026-08-24 18:11:00	3
2217	25	25	SALE	10	2026-08-25 15:30:00	3
2218	25	25	SALE	11	2026-08-26 19:44:00	3
2219	25	25	SALE	10	2026-08-27 15:19:00	3
2220	25	25	SALE	13	2026-08-28 18:08:00	3
2221	25	25	SALE	10	2026-08-29 10:20:00	3
2222	25	25	SALE	13	2026-08-30 10:45:00	3
2223	25	25	SALE	8	2026-08-31 17:11:00	3
2224	25	25	SALE	9	2026-09-01 15:52:00	3
2225	25	25	SALE	8	2026-09-02 20:01:00	3
2226	25	25	SALE	12	2026-09-03 15:35:00	3
2227	25	25	SALE	8	2026-09-04 17:50:00	3
2228	25	25	SALE	12	2026-09-05 17:31:00	3
2229	25	25	SALE	10	2026-09-06 10:33:00	3
2230	25	25	SALE	11	2026-09-07 18:34:00	3
2231	25	25	SALE	6	2026-09-08 20:52:00	3
2232	25	25	SALE	10	2026-09-09 19:07:00	3
2233	25	25	SALE	9	2026-09-10 12:42:00	3
2234	25	25	SALE	9	2026-09-11 10:11:00	3
2235	25	25	SALE	12	2026-09-12 18:44:00	3
2236	25	25	SALE	13	2026-09-13 11:00:00	3
2237	25	25	SALE	9	2026-09-14 17:28:00	3
2238	25	25	SALE	11	2026-09-15 14:07:00	3
2239	25	25	SALE	9	2026-09-16 09:08:00	3
2240	25	25	SALE	10	2026-09-17 18:13:00	3
2241	25	25	SALE	7	2026-09-18 19:10:00	3
2242	25	25	SALE	10	2026-09-19 10:35:00	3
2243	25	25	SALE	13	2026-09-20 13:54:00	3
2244	25	25	SALE	7	2026-09-21 09:05:00	3
2245	25	25	SALE	9	2026-09-22 10:32:00	3
2246	25	25	SALE	7	2026-09-23 13:23:00	3
2247	25	25	SALE	6	2026-09-24 17:10:00	3
2248	25	25	SALE	7	2026-09-25 15:42:00	3
2249	25	25	SALE	19	2026-09-26 09:15:00	3
2250	25	25	SALE	14	2026-09-27 13:02:00	3
2251	25	25	SALE	7	2026-09-28 17:57:00	3
2252	25	25	SALE	11	2026-09-29 13:42:00	3
2253	25	25	SALE	9	2026-09-30 17:28:00	3
2254	25	25	SALE	9	2026-10-01 11:36:00	3
2255	25	25	SALE	6	2026-10-02 16:44:00	3
2256	25	25	SALE	14	2026-10-03 14:33:00	3
2257	25	25	SALE	15	2026-10-04 14:38:00	3
2258	25	25	SALE	12	2026-10-05 17:32:00	3
2259	25	25	SALE	4	2026-10-06 12:44:00	3
2260	25	25	SALE	7	2026-10-07 10:42:00	3
2261	25	25	SALE	4	2026-10-08 09:15:00	3
2262	25	25	SALE	8	2026-10-09 09:12:00	3
2263	25	25	SALE	12	2026-10-10 11:19:00	3
2264	25	25	SALE	14	2026-10-11 12:08:00	3
2265	25	25	SALE	11	2026-10-12 18:35:00	3
2266	25	25	SALE	11	2026-10-13 12:37:00	3
2267	25	25	SALE	7	2026-10-14 14:17:00	3
2268	25	25	SALE	11	2026-10-15 11:46:00	3
2269	25	25	SALE	11	2026-10-16 18:27:00	3
2270	25	25	SALE	33	2026-10-17 10:35:00	3
2271	25	25	SALE	10	2026-10-18 13:16:00	3
2272	25	25	SALE	10	2026-10-19 15:41:00	3
2273	25	25	SALE	9	2026-10-20 11:25:00	3
2274	25	25	SALE	11	2026-10-21 16:05:00	3
2275	25	25	SALE	6	2026-10-22 13:43:00	3
2276	26	26	RECEIPT	2660	2026-07-25 08:00:00	2
2277	26	26	SALE	33	2026-07-25 09:49:00	3
2278	26	26	SALE	30	2026-07-26 19:15:00	3
2279	26	26	SALE	24	2026-07-27 09:43:00	3
2280	26	26	SALE	22	2026-07-28 14:27:00	3
2281	26	26	SALE	28	2026-07-29 18:47:00	3
2282	26	26	SALE	19	2026-07-30 09:27:00	3
2283	26	26	SALE	30	2026-07-31 16:18:00	3
2284	26	26	SALE	35	2026-08-01 13:31:00	3
2285	26	26	SALE	38	2026-08-02 10:48:00	3
2286	26	26	SALE	29	2026-08-03 15:15:00	3
2287	26	26	SALE	22	2026-08-04 18:09:00	3
2288	26	26	SALE	28	2026-08-05 20:32:00	3
2289	26	26	SALE	25	2026-08-06 11:15:00	3
2290	26	26	SALE	26	2026-08-07 13:49:00	3
2291	26	26	SALE	43	2026-08-08 10:55:00	3
2292	26	26	SALE	43	2026-08-09 13:44:00	3
2293	26	26	SALE	28	2026-08-10 12:42:00	3
2294	26	26	SALE	20	2026-08-11 15:12:00	3
2295	26	26	SALE	29	2026-08-12 16:45:00	3
2296	26	26	SALE	20	2026-08-13 10:44:00	3
2297	26	26	SALE	31	2026-08-14 20:32:00	3
2298	26	26	SALE	45	2026-08-15 18:11:00	3
2299	26	26	SALE	31	2026-08-16 12:54:00	3
2300	26	26	SALE	24	2026-08-17 18:40:00	3
2301	26	26	SALE	25	2026-08-18 19:09:00	3
2302	26	26	SALE	25	2026-08-19 12:07:00	3
2303	26	26	SALE	28	2026-08-20 11:25:00	3
2304	26	26	SALE	28	2026-08-21 09:17:00	3
2305	26	26	SALE	44	2026-08-22 12:59:00	3
2306	26	26	SALE	34	2026-08-23 11:27:00	3
2307	26	26	SALE	31	2026-08-24 09:39:00	3
2308	26	26	SALE	38	2026-08-25 12:05:00	3
2309	26	26	SALE	24	2026-08-26 09:24:00	3
2310	26	26	SALE	30	2026-08-27 15:33:00	3
2311	26	26	SALE	27	2026-08-28 13:44:00	3
2312	26	26	SALE	33	2026-08-29 19:14:00	3
2313	26	26	SALE	36	2026-08-30 12:21:00	3
2314	26	26	SALE	26	2026-08-31 15:30:00	3
2315	26	26	SALE	26	2026-09-01 09:32:00	3
2316	26	26	SALE	26	2026-09-02 15:41:00	3
2317	26	26	SALE	15	2026-09-03 09:19:00	3
2318	26	26	SALE	25	2026-09-04 10:17:00	3
2319	26	26	SALE	34	2026-09-05 14:17:00	3
2320	26	26	SALE	32	2026-09-06 14:45:00	3
2321	26	26	SALE	23	2026-09-07 15:15:00	3
2322	26	26	SALE	20	2026-09-08 14:57:00	3
2323	26	26	SALE	25	2026-09-09 09:11:00	3
2324	26	26	SALE	17	2026-09-10 09:00:00	3
2325	26	26	SALE	25	2026-09-11 09:42:00	3
2326	26	26	SALE	45	2026-09-12 20:20:00	3
2327	26	26	SALE	30	2026-09-13 12:18:00	3
2328	26	26	SALE	21	2026-09-14 16:17:00	3
2329	26	26	SALE	29	2026-09-15 18:06:00	3
2330	26	26	SALE	21	2026-09-16 15:11:00	3
2331	26	26	SALE	28	2026-09-17 13:31:00	3
2332	26	26	SALE	20	2026-09-18 14:21:00	3
2333	26	26	SALE	33	2026-09-19 13:07:00	3
2334	26	26	SALE	36	2026-09-20 10:42:00	3
2335	26	26	SALE	25	2026-09-21 09:43:00	3
2336	26	26	SALE	23	2026-09-22 17:49:00	3
2337	26	26	SALE	27	2026-09-23 11:21:00	3
2338	26	26	SALE	33	2026-09-24 14:47:00	3
2339	26	26	SALE	21	2026-09-25 14:47:00	3
2340	26	26	SALE	48	2026-09-26 18:33:00	3
2341	26	26	SALE	31	2026-09-27 18:23:00	3
2342	26	26	SALE	21	2026-09-28 12:41:00	3
2343	26	26	SALE	66	2026-09-29 13:13:00	3
2344	26	26	SALE	29	2026-09-30 18:24:00	3
2345	26	26	SALE	24	2026-10-01 10:56:00	3
2346	26	26	SALE	27	2026-10-02 10:08:00	3
2347	26	26	SALE	37	2026-10-03 19:47:00	3
2348	26	26	SALE	35	2026-10-04 18:07:00	3
2349	26	26	SALE	26	2026-10-05 09:37:00	3
2350	26	26	SALE	30	2026-10-06 19:52:00	3
2351	26	26	SALE	29	2026-10-07 12:12:00	3
2352	26	26	SALE	33	2026-10-08 20:28:00	3
2353	26	26	SALE	27	2026-10-09 10:04:00	3
2354	26	26	SALE	32	2026-10-10 17:39:00	3
2355	26	26	SALE	38	2026-10-11 14:19:00	3
2356	26	26	SALE	28	2026-10-12 20:30:00	3
2357	26	26	SALE	25	2026-10-13 12:34:00	3
2358	26	26	SALE	14	2026-10-14 20:09:00	3
2359	26	26	SALE	18	2026-10-15 09:08:00	3
2360	26	26	SALE	26	2026-10-16 12:26:00	3
2361	26	26	SALE	38	2026-10-17 17:45:00	3
2362	26	26	SALE	29	2026-10-18 13:57:00	3
2363	26	26	SALE	14	2026-10-19 17:22:00	3
2364	26	26	SALE	25	2026-10-20 14:28:00	3
2365	26	26	SALE	27	2026-10-21 19:45:00	3
2366	26	26	SALE	27	2026-10-22 10:58:00	3
2367	27	27	RECEIPT	2631	2026-07-25 08:00:00	2
2368	27	27	SALE	23	2026-07-25 15:26:00	3
2369	27	27	SALE	30	2026-07-26 17:31:00	3
2370	27	27	SALE	18	2026-07-27 17:34:00	3
2371	27	27	SALE	30	2026-07-28 16:34:00	3
2372	27	27	SALE	30	2026-07-29 17:52:00	3
2373	27	27	SALE	24	2026-07-30 12:24:00	3
2374	27	27	SALE	15	2026-07-31 10:37:00	3
2375	27	27	SALE	26	2026-08-01 20:26:00	3
2376	27	27	SALE	24	2026-08-02 17:36:00	3
2377	27	27	SALE	18	2026-08-03 20:51:00	3
2378	27	27	SALE	25	2026-08-04 20:14:00	3
2379	27	27	SALE	59	2026-08-05 20:05:00	3
2380	27	27	SALE	15	2026-08-06 12:23:00	3
2381	27	27	SALE	20	2026-08-07 09:13:00	3
2382	27	27	SALE	29	2026-08-08 09:23:00	3
2383	27	27	SALE	30	2026-08-09 17:30:00	3
2384	27	27	SALE	19	2026-08-10 11:58:00	3
2385	27	27	SALE	26	2026-08-11 10:03:00	3
2386	27	27	SALE	25	2026-08-12 14:23:00	3
2387	27	27	SALE	26	2026-08-13 11:18:00	3
2388	27	27	SALE	23	2026-08-14 16:09:00	3
2389	27	27	SALE	28	2026-08-15 17:59:00	3
2390	27	27	SALE	26	2026-08-16 15:15:00	3
2391	27	27	SALE	29	2026-08-17 12:52:00	3
2392	27	27	SALE	26	2026-08-18 12:03:00	3
2393	27	27	SALE	26	2026-08-19 20:08:00	3
2394	27	27	SALE	20	2026-08-20 10:44:00	3
2395	27	27	SALE	20	2026-08-21 20:09:00	3
2396	27	27	SALE	27	2026-08-22 15:46:00	3
2397	27	27	SALE	30	2026-08-23 09:44:00	3
2398	27	27	SALE	14	2026-08-24 15:23:00	3
2399	27	27	SALE	17	2026-08-25 09:44:00	3
2400	27	27	SALE	20	2026-08-26 10:42:00	3
2401	27	27	SALE	26	2026-08-27 18:04:00	3
2402	27	27	SALE	17	2026-08-28 16:53:00	3
2403	27	27	SALE	30	2026-08-29 18:55:00	3
2404	27	27	SALE	21	2026-08-30 11:01:00	3
2405	27	27	SALE	22	2026-08-31 11:23:00	3
2406	27	27	SALE	15	2026-09-01 11:05:00	3
2407	27	27	SALE	21	2026-09-02 12:04:00	3
2408	27	27	SALE	22	2026-09-03 09:36:00	3
2409	27	27	SALE	25	2026-09-04 15:09:00	3
2410	27	27	SALE	24	2026-09-05 11:30:00	3
2411	27	27	SALE	36	2026-09-06 20:08:00	3
2412	27	27	SALE	23	2026-09-07 20:33:00	3
2413	27	27	SALE	23	2026-09-08 20:19:00	3
2414	27	27	SALE	15	2026-09-09 16:26:00	3
2415	27	27	SALE	24	2026-09-10 20:21:00	3
2416	27	27	SALE	22	2026-09-11 16:50:00	3
2417	27	27	SALE	76	2026-09-12 19:44:00	3
2418	27	27	SALE	34	2026-09-13 09:18:00	3
2419	27	27	SALE	25	2026-09-14 10:09:00	3
2420	27	27	SALE	39	2026-09-15 09:56:00	3
2421	27	27	SALE	16	2026-09-16 19:02:00	3
2422	27	27	SALE	23	2026-09-17 18:48:00	3
2423	27	27	SALE	13	2026-09-18 11:32:00	3
2424	27	27	SALE	35	2026-09-19 11:00:00	3
2425	27	27	SALE	23	2026-09-20 15:53:00	3
2426	27	27	SALE	17	2026-09-21 15:43:00	3
2427	27	27	SALE	19	2026-09-22 16:35:00	3
2428	27	27	SALE	25	2026-09-23 20:53:00	3
2429	27	27	SALE	21	2026-09-24 13:58:00	3
2430	27	27	SALE	20	2026-09-25 18:32:00	3
2431	27	27	SALE	27	2026-09-26 13:45:00	3
2432	27	27	SALE	25	2026-09-27 12:27:00	3
2433	27	27	SALE	29	2026-09-28 11:17:00	3
2434	27	27	SALE	18	2026-09-29 10:33:00	3
2435	27	27	SALE	12	2026-09-30 15:08:00	3
2436	27	27	SALE	22	2026-10-01 20:13:00	3
2437	27	27	SALE	30	2026-10-02 15:39:00	3
2438	27	27	SALE	22	2026-10-03 09:14:00	3
2439	27	27	SALE	33	2026-10-04 15:11:00	3
2440	27	27	SALE	17	2026-10-05 20:35:00	3
2441	27	27	SALE	22	2026-10-06 18:53:00	3
2442	27	27	SALE	25	2026-10-07 10:52:00	3
2443	27	27	SALE	16	2026-10-08 20:29:00	3
2444	27	27	SALE	22	2026-10-09 16:20:00	3
2445	27	27	SALE	25	2026-10-10 19:41:00	3
2446	27	27	SALE	32	2026-10-11 15:52:00	3
2447	27	27	SALE	13	2026-10-12 15:10:00	3
2448	27	27	SALE	20	2026-10-13 09:51:00	3
2449	27	27	SALE	18	2026-10-14 14:41:00	3
2450	27	27	SALE	23	2026-10-15 15:12:00	3
2451	27	27	SALE	10	2026-10-16 13:06:00	3
2452	27	27	SALE	27	2026-10-17 10:04:00	3
2453	27	27	SALE	24	2026-10-18 14:38:00	3
2454	27	27	SALE	17	2026-10-19 14:01:00	3
2455	27	27	SALE	24	2026-10-20 12:18:00	3
2456	27	27	SALE	15	2026-10-21 11:34:00	3
2457	27	27	SALE	17	2026-10-22 10:04:00	3
2458	28	28	RECEIPT	2342	2026-07-25 08:00:00	2
2459	28	28	SALE	34	2026-07-25 11:38:00	3
2460	28	28	SALE	26	2026-07-26 15:13:00	3
2461	28	28	SALE	19	2026-07-27 14:13:00	3
2462	28	28	SALE	21	2026-07-28 12:43:00	3
2463	28	28	SALE	23	2026-07-29 18:00:00	3
2464	28	28	SALE	19	2026-07-30 14:52:00	3
2465	28	28	SALE	15	2026-07-31 14:01:00	3
2466	28	28	SALE	38	2026-08-01 13:57:00	3
2467	28	28	SALE	23	2026-08-02 13:32:00	3
2468	28	28	SALE	21	2026-08-03 10:44:00	3
2469	28	28	SALE	15	2026-08-04 16:41:00	3
2470	28	28	SALE	26	2026-08-05 16:26:00	3
2471	28	28	SALE	19	2026-08-06 15:22:00	3
2472	28	28	SALE	18	2026-08-07 14:53:00	3
2473	28	28	SALE	30	2026-08-08 17:27:00	3
2474	28	28	SALE	26	2026-08-09 17:48:00	3
2475	28	28	SALE	22	2026-08-10 14:07:00	3
2476	28	28	SALE	18	2026-08-11 11:29:00	3
2477	28	28	SALE	23	2026-08-12 15:23:00	3
2478	28	28	SALE	24	2026-08-13 11:35:00	3
2479	28	28	SALE	24	2026-08-14 18:10:00	3
2480	28	28	SALE	27	2026-08-15 17:27:00	3
2481	28	28	SALE	24	2026-08-16 15:18:00	3
2482	28	28	SALE	24	2026-08-17 19:44:00	3
2483	28	28	SALE	18	2026-08-18 19:27:00	3
2484	28	28	SALE	13	2026-08-19 19:18:00	3
2485	28	28	SALE	12	2026-08-20 20:39:00	3
2486	28	28	SALE	13	2026-08-21 10:05:00	3
2487	28	28	SALE	32	2026-08-22 10:05:00	3
2488	28	28	SALE	29	2026-08-23 19:01:00	3
2489	28	28	SALE	23	2026-08-24 18:59:00	3
2490	28	28	SALE	16	2026-08-25 15:06:00	3
2491	28	28	SALE	19	2026-08-26 16:47:00	3
2492	28	28	SALE	20	2026-08-27 18:59:00	3
2493	28	28	SALE	24	2026-08-28 17:06:00	3
2494	28	28	SALE	31	2026-08-29 19:28:00	3
2495	28	28	SALE	20	2026-08-30 17:37:00	3
2496	28	28	SALE	22	2026-08-31 09:42:00	3
2497	28	28	SALE	15	2026-09-01 13:54:00	3
2498	28	28	SALE	19	2026-09-02 15:13:00	3
2499	28	28	SALE	15	2026-09-03 12:49:00	3
2500	28	28	SALE	15	2026-09-04 16:35:00	3
2501	28	28	SALE	26	2026-09-05 15:07:00	3
2502	28	28	SALE	28	2026-09-06 12:54:00	3
2503	28	28	SALE	20	2026-09-07 16:07:00	3
2504	28	28	SALE	19	2026-09-08 14:50:00	3
2505	28	28	SALE	20	2026-09-09 16:26:00	3
2506	28	28	SALE	13	2026-09-10 19:45:00	3
2507	28	28	SALE	22	2026-09-11 20:25:00	3
2508	28	28	SALE	30	2026-09-12 09:23:00	3
2509	28	28	SALE	26	2026-09-13 12:32:00	3
2510	28	28	SALE	16	2026-09-14 13:17:00	3
2511	28	28	SALE	20	2026-09-15 19:16:00	3
2512	28	28	SALE	17	2026-09-16 13:53:00	3
2513	28	28	SALE	23	2026-09-17 15:43:00	3
2514	28	28	SALE	18	2026-09-18 12:00:00	3
2515	28	28	SALE	22	2026-09-19 15:02:00	3
2516	28	28	SALE	32	2026-09-20 09:01:00	3
2517	28	28	SALE	14	2026-09-21 11:50:00	3
2518	28	28	SALE	20	2026-09-22 14:53:00	3
2519	28	28	SALE	20	2026-09-23 17:52:00	3
2520	28	28	SALE	24	2026-09-24 20:38:00	3
2521	28	28	SALE	25	2026-09-25 14:21:00	3
2522	28	28	SALE	31	2026-09-26 11:36:00	3
2523	28	28	SALE	32	2026-09-27 15:15:00	3
2524	28	28	SALE	20	2026-09-28 17:25:00	3
2525	28	28	SALE	20	2026-09-29 12:39:00	3
2526	28	28	SALE	21	2026-09-30 19:25:00	3
2527	28	28	SALE	22	2026-10-01 09:51:00	3
2528	28	28	SALE	16	2026-10-02 18:27:00	3
2529	28	28	SALE	29	2026-10-03 11:40:00	3
2530	28	28	SALE	27	2026-10-04 15:46:00	3
2531	28	28	SALE	18	2026-10-05 11:25:00	3
2532	28	28	SALE	21	2026-10-06 14:33:00	3
2533	28	28	SALE	13	2026-10-07 11:27:00	3
2534	28	28	SALE	18	2026-10-08 12:06:00	3
2535	28	28	SALE	23	2026-10-09 20:51:00	3
2536	28	28	SALE	24	2026-10-10 11:32:00	3
2537	28	28	SALE	25	2026-10-11 10:40:00	3
2538	28	28	SALE	14	2026-10-12 18:50:00	3
2539	28	28	SALE	22	2026-10-13 15:53:00	3
2540	28	28	SALE	13	2026-10-14 19:58:00	3
2541	28	28	SALE	27	2026-10-15 13:53:00	3
2542	28	28	SALE	20	2026-10-16 17:10:00	3
2543	28	28	SALE	27	2026-10-17 14:13:00	3
2544	28	28	SALE	22	2026-10-18 10:05:00	3
2545	28	28	SALE	26	2026-10-19 09:27:00	3
2546	28	28	SALE	16	2026-10-20 09:40:00	3
2547	28	28	SALE	18	2026-10-21 18:09:00	3
2548	28	28	SALE	19	2026-10-22 09:39:00	3
2549	29	29	RECEIPT	1798	2026-07-25 08:00:00	2
2550	29	29	SALE	23	2026-07-25 11:20:00	3
2551	29	29	SALE	21	2026-07-26 11:48:00	3
2552	29	29	SALE	11	2026-07-27 18:56:00	3
2553	29	29	SALE	16	2026-07-28 15:40:00	3
2554	29	29	SALE	17	2026-07-29 16:42:00	3
2555	29	29	SALE	13	2026-07-30 10:33:00	3
2556	29	29	SALE	16	2026-07-31 17:15:00	3
2557	29	29	SALE	16	2026-08-01 18:30:00	3
2558	29	29	SALE	19	2026-08-02 19:31:00	3
2559	29	29	SALE	12	2026-08-03 13:20:00	3
2560	29	29	SALE	11	2026-08-04 20:30:00	3
2561	29	29	SALE	16	2026-08-05 12:05:00	3
2562	29	29	SALE	16	2026-08-06 13:49:00	3
2563	29	29	SALE	14	2026-08-07 13:45:00	3
2564	29	29	SALE	19	2026-08-08 10:22:00	3
2565	29	29	SALE	22	2026-08-09 17:53:00	3
2566	29	29	SALE	19	2026-08-10 12:42:00	3
2567	29	29	SALE	17	2026-08-11 19:47:00	3
2568	29	29	SALE	20	2026-08-12 12:44:00	3
2569	29	29	SALE	26	2026-08-13 10:04:00	3
2570	29	29	SALE	11	2026-08-14 16:03:00	3
2571	29	29	SALE	21	2026-08-15 12:00:00	3
2572	29	29	SALE	18	2026-08-16 19:13:00	3
2573	29	29	SALE	13	2026-08-17 16:52:00	3
2574	29	29	SALE	17	2026-08-18 15:12:00	3
2575	29	29	SALE	14	2026-08-19 16:06:00	3
2576	29	29	SALE	13	2026-08-20 14:13:00	3
2577	29	29	SALE	15	2026-08-21 18:48:00	3
2578	29	29	SALE	19	2026-08-22 17:32:00	3
2579	29	29	SALE	24	2026-08-23 14:48:00	3
2580	29	29	SALE	8	2026-08-24 13:45:00	3
2581	29	29	SALE	16	2026-08-25 16:41:00	3
2582	29	29	SALE	14	2026-08-26 11:54:00	3
2583	29	29	SALE	20	2026-08-27 17:06:00	3
2584	29	29	SALE	13	2026-08-28 11:14:00	3
2585	29	29	SALE	23	2026-08-29 14:24:00	3
2586	29	29	SALE	17	2026-08-30 16:55:00	3
2587	29	29	SALE	17	2026-08-31 18:32:00	3
2588	29	29	SALE	17	2026-09-01 12:49:00	3
2589	29	29	SALE	8	2026-09-02 15:12:00	3
2590	29	29	SALE	11	2026-09-03 10:17:00	3
2591	29	29	SALE	17	2026-09-04 15:10:00	3
2592	29	29	SALE	18	2026-09-05 19:19:00	3
2593	29	29	SALE	23	2026-09-06 18:41:00	3
2594	29	29	SALE	15	2026-09-07 10:09:00	3
2595	29	29	SALE	16	2026-09-08 16:56:00	3
2596	29	29	SALE	13	2026-09-09 10:47:00	3
2597	29	29	SALE	20	2026-09-10 10:15:00	3
2598	29	29	SALE	15	2026-09-11 09:57:00	3
2599	29	29	SALE	21	2026-09-12 16:11:00	3
2600	29	29	SALE	25	2026-09-13 13:01:00	3
2601	29	29	SALE	17	2026-09-14 16:42:00	3
2602	29	29	SALE	40	2026-09-15 17:28:00	3
2603	29	29	SALE	17	2026-09-16 14:16:00	3
2604	29	29	SALE	17	2026-09-17 10:59:00	3
2605	29	29	SALE	9	2026-09-18 17:05:00	3
2606	29	29	SALE	20	2026-09-19 14:27:00	3
2607	29	29	SALE	21	2026-09-20 12:09:00	3
2608	29	29	SALE	16	2026-09-21 15:32:00	3
2609	29	29	SALE	14	2026-09-22 15:32:00	3
2610	29	29	SALE	15	2026-09-23 14:03:00	3
2611	29	29	SALE	12	2026-09-24 16:17:00	3
2612	29	29	SALE	16	2026-09-25 14:06:00	3
2613	29	29	SALE	17	2026-09-26 09:41:00	3
2614	29	29	SALE	19	2026-09-27 15:46:00	3
2615	29	29	SALE	18	2026-09-28 15:12:00	3
2616	29	29	SALE	11	2026-09-29 13:12:00	3
2617	29	29	SALE	10	2026-09-30 15:11:00	3
2618	29	29	SALE	14	2026-10-01 18:17:00	3
2619	29	29	SALE	21	2026-10-02 17:38:00	3
2620	29	29	SALE	26	2026-10-03 16:33:00	3
2621	29	29	SALE	21	2026-10-04 15:06:00	3
2622	29	29	SALE	15	2026-10-05 19:03:00	3
2623	29	29	SALE	13	2026-10-06 19:15:00	3
2624	29	29	SALE	13	2026-10-07 10:14:00	3
2625	29	29	SALE	14	2026-10-08 10:03:00	3
2626	29	29	SALE	14	2026-10-09 09:36:00	3
2627	29	29	SALE	19	2026-10-10 13:15:00	3
2628	29	29	SALE	20	2026-10-11 10:34:00	3
2629	29	29	SALE	32	2026-10-12 10:17:00	3
2630	29	29	SALE	13	2026-10-13 12:56:00	3
2631	29	29	SALE	19	2026-10-14 18:44:00	3
2632	29	29	SALE	17	2026-10-15 20:25:00	3
2633	29	29	SALE	21	2026-10-16 15:25:00	3
2634	29	29	SALE	28	2026-10-17 10:14:00	3
2635	29	29	SALE	19	2026-10-18 20:52:00	3
2636	29	29	SALE	16	2026-10-19 20:17:00	3
2637	29	29	SALE	15	2026-10-20 16:13:00	3
2638	29	29	SALE	16	2026-10-21 11:50:00	3
2639	29	29	SALE	13	2026-10-22 12:22:00	3
2640	30	30	RECEIPT	1450	2026-07-25 08:00:00	2
2641	30	30	SALE	37	2026-07-25 10:00:00	3
2642	30	30	SALE	16	2026-07-26 11:38:00	3
2643	30	30	SALE	12	2026-07-27 10:33:00	3
2644	30	30	SALE	7	2026-07-28 10:15:00	3
2645	30	30	SALE	11	2026-07-29 12:06:00	3
2646	30	30	SALE	11	2026-07-30 16:01:00	3
2647	30	30	SALE	15	2026-07-31 17:28:00	3
2648	30	30	SALE	15	2026-08-01 15:03:00	3
2649	30	30	SALE	47	2026-08-02 10:19:00	3
2650	30	30	SALE	16	2026-08-03 15:30:00	3
2651	30	30	SALE	17	2026-08-04 11:52:00	3
2652	30	30	SALE	12	2026-08-05 12:53:00	3
2653	30	30	SALE	16	2026-08-06 17:16:00	3
2654	30	30	SALE	12	2026-08-07 18:43:00	3
2655	30	30	SALE	17	2026-08-08 16:54:00	3
2656	30	30	SALE	13	2026-08-09 19:39:00	3
2657	30	30	SALE	10	2026-08-10 10:27:00	3
2658	30	30	SALE	12	2026-08-11 11:40:00	3
2659	30	30	SALE	12	2026-08-12 09:11:00	3
2660	30	30	SALE	15	2026-08-13 11:52:00	3
2661	30	30	SALE	11	2026-08-14 20:42:00	3
2662	30	30	SALE	20	2026-08-15 12:10:00	3
2663	30	30	SALE	16	2026-08-16 17:47:00	3
2664	30	30	SALE	15	2026-08-17 20:34:00	3
2665	30	30	SALE	11	2026-08-18 12:30:00	3
2666	30	30	SALE	13	2026-08-19 16:18:00	3
2667	30	30	SALE	15	2026-08-20 13:42:00	3
2668	30	30	SALE	13	2026-08-21 10:37:00	3
2669	30	30	SALE	21	2026-08-22 16:23:00	3
2670	30	30	SALE	19	2026-08-23 19:17:00	3
2671	30	30	SALE	10	2026-08-24 15:24:00	3
2672	30	30	SALE	10	2026-08-25 20:51:00	3
2673	30	30	SALE	13	2026-08-26 10:29:00	3
2674	30	30	SALE	11	2026-08-27 15:52:00	3
2675	30	30	SALE	10	2026-08-28 15:09:00	3
2676	30	30	SALE	19	2026-08-29 09:18:00	3
2677	30	30	SALE	16	2026-08-30 16:07:00	3
2678	30	30	SALE	8	2026-08-31 18:24:00	3
2679	30	30	SALE	8	2026-09-01 09:37:00	3
2680	30	30	SALE	10	2026-09-02 13:02:00	3
2681	30	30	SALE	17	2026-09-03 19:41:00	3
2682	30	30	SALE	12	2026-09-04 19:39:00	3
2683	30	30	SALE	16	2026-09-05 16:02:00	3
2684	30	30	SALE	20	2026-09-06 14:08:00	3
2685	30	30	SALE	11	2026-09-07 16:56:00	3
2686	30	30	SALE	15	2026-09-08 20:29:00	3
2687	30	30	SALE	33	2026-09-09 13:00:00	3
2688	30	30	SALE	14	2026-09-10 11:22:00	3
2689	30	30	SALE	13	2026-09-11 17:54:00	3
2690	30	30	SALE	18	2026-09-12 17:13:00	3
2691	30	30	SALE	12	2026-09-13 14:57:00	3
2692	30	30	SALE	10	2026-09-14 20:33:00	3
2693	30	30	SALE	12	2026-09-15 15:32:00	3
2694	30	30	SALE	9	2026-09-16 10:11:00	3
2695	30	30	SALE	17	2026-09-17 19:09:00	3
2696	30	30	SALE	13	2026-09-18 14:41:00	3
2697	30	30	SALE	12	2026-09-19 20:36:00	3
2698	30	30	SALE	21	2026-09-20 14:29:00	3
2699	30	30	SALE	13	2026-09-21 20:54:00	3
2700	30	30	SALE	14	2026-09-22 11:17:00	3
2701	30	30	SALE	15	2026-09-23 19:19:00	3
2702	30	30	SALE	15	2026-09-24 15:04:00	3
2703	30	30	SALE	13	2026-09-25 19:30:00	3
2704	30	30	SALE	20	2026-09-26 15:30:00	3
2705	30	30	SALE	17	2026-09-27 18:42:00	3
2706	30	30	SALE	8	2026-09-28 11:36:00	3
2707	30	30	SALE	11	2026-09-29 20:59:00	3
2708	30	30	SALE	9	2026-09-30 17:49:00	3
2709	30	30	SALE	10	2026-10-01 19:33:00	3
2710	30	30	SALE	14	2026-10-02 13:08:00	3
2711	30	30	SALE	22	2026-10-03 20:20:00	3
2712	30	30	SALE	17	2026-10-04 18:37:00	3
2713	30	30	SALE	13	2026-10-05 14:37:00	3
2714	30	30	SALE	9	2026-10-06 18:53:00	3
2715	30	30	SALE	16	2026-10-07 15:04:00	3
2716	30	30	SALE	9	2026-10-08 09:01:00	3
2717	30	30	SALE	15	2026-10-09 20:10:00	3
2718	30	30	SALE	20	2026-10-10 12:06:00	3
2719	30	30	SALE	19	2026-10-11 19:06:00	3
2720	30	30	SALE	13	2026-10-12 16:59:00	3
2721	30	30	SALE	8	2026-10-13 19:30:00	3
2722	30	30	SALE	10	2026-10-14 14:48:00	3
2723	30	30	SALE	13	2026-10-15 12:49:00	3
2724	30	30	SALE	11	2026-10-16 20:50:00	3
2725	30	30	SALE	16	2026-10-17 12:06:00	3
2726	30	30	SALE	15	2026-10-18 11:46:00	3
2727	30	30	SALE	15	2026-10-19 15:48:00	3
2728	30	30	SALE	10	2026-10-20 15:59:00	3
2729	30	30	SALE	11	2026-10-21 10:03:00	3
2730	30	30	SALE	6	2026-10-22 18:16:00	3
2731	31	31	RECEIPT	1288	2026-07-25 08:00:00	2
2732	31	31	SALE	15	2026-07-25 09:58:00	3
2733	31	31	SALE	15	2026-07-26 18:48:00	3
2734	31	31	SALE	13	2026-07-27 14:59:00	3
2735	31	31	SALE	10	2026-07-28 13:51:00	3
2736	31	31	SALE	14	2026-07-29 18:13:00	3
2737	31	31	SALE	11	2026-07-30 09:21:00	3
2738	31	31	SALE	9	2026-07-31 20:53:00	3
2739	31	31	SALE	15	2026-08-01 18:27:00	3
2740	31	31	SALE	17	2026-08-02 15:50:00	3
2741	31	31	SALE	14	2026-08-03 20:59:00	3
2742	31	31	SALE	12	2026-08-04 20:48:00	3
2743	31	31	SALE	15	2026-08-05 09:51:00	3
2744	31	31	SALE	9	2026-08-06 10:35:00	3
2745	31	31	SALE	13	2026-08-07 15:46:00	3
2746	31	31	SALE	19	2026-08-08 19:18:00	3
2747	31	31	SALE	14	2026-08-09 17:29:00	3
2748	31	31	SALE	9	2026-08-10 15:36:00	3
2749	31	31	SALE	11	2026-08-11 20:36:00	3
2750	31	31	SALE	12	2026-08-12 17:16:00	3
2751	31	31	SALE	12	2026-08-13 11:24:00	3
2752	31	31	SALE	12	2026-08-14 16:47:00	3
2753	31	31	SALE	15	2026-08-15 12:08:00	3
2754	31	31	SALE	13	2026-08-16 09:17:00	3
2755	31	31	SALE	10	2026-08-17 19:17:00	3
2756	31	31	SALE	12	2026-08-18 10:15:00	3
2757	31	31	SALE	10	2026-08-19 17:18:00	3
2758	31	31	SALE	15	2026-08-20 14:36:00	3
2759	31	31	SALE	7	2026-08-21 15:02:00	3
2760	31	31	SALE	19	2026-08-22 18:17:00	3
2761	31	31	SALE	13	2026-08-23 14:17:00	3
2762	31	31	SALE	13	2026-08-24 19:16:00	3
2763	31	31	SALE	13	2026-08-25 19:51:00	3
2764	31	31	SALE	13	2026-08-26 18:00:00	3
2765	31	31	SALE	11	2026-08-27 10:19:00	3
2766	31	31	SALE	11	2026-08-28 18:42:00	3
2767	31	31	SALE	15	2026-08-29 14:53:00	3
2768	31	31	SALE	17	2026-08-30 13:54:00	3
2769	31	31	SALE	10	2026-08-31 11:28:00	3
2770	31	31	SALE	14	2026-09-01 16:01:00	3
2771	31	31	SALE	9	2026-09-02 16:00:00	3
2772	31	31	SALE	16	2026-09-03 16:02:00	3
2773	31	31	SALE	10	2026-09-04 14:30:00	3
2774	31	31	SALE	9	2026-09-05 19:54:00	3
2775	31	31	SALE	13	2026-09-06 17:13:00	3
2776	31	31	SALE	8	2026-09-07 15:03:00	3
2777	31	31	SALE	11	2026-09-08 18:05:00	3
2778	31	31	SALE	14	2026-09-09 13:57:00	3
2779	31	31	SALE	6	2026-09-10 18:35:00	3
2780	31	31	SALE	12	2026-09-11 14:04:00	3
2781	31	31	SALE	12	2026-09-12 16:11:00	3
2782	31	31	SALE	15	2026-09-13 13:49:00	3
2783	31	31	SALE	11	2026-09-14 13:16:00	3
2784	31	31	SALE	9	2026-09-15 16:08:00	3
2785	31	31	SALE	12	2026-09-16 12:40:00	3
2786	31	31	SALE	16	2026-09-17 11:09:00	3
2787	31	31	SALE	7	2026-09-18 18:41:00	3
2788	31	31	SALE	17	2026-09-19 09:14:00	3
2789	31	31	SALE	15	2026-09-20 10:41:00	3
2790	31	31	SALE	14	2026-09-21 09:11:00	3
2791	31	31	SALE	8	2026-09-22 19:32:00	3
2792	31	31	SALE	14	2026-09-23 16:37:00	3
2793	31	31	SALE	11	2026-09-24 14:02:00	3
2794	31	31	SALE	12	2026-09-25 17:45:00	3
2795	31	31	SALE	16	2026-09-26 12:03:00	3
2796	31	31	SALE	14	2026-09-27 20:16:00	3
2797	31	31	SALE	14	2026-09-28 13:01:00	3
2798	31	31	SALE	12	2026-09-29 19:54:00	3
2799	31	31	SALE	12	2026-09-30 14:34:00	3
2800	31	31	SALE	11	2026-10-01 20:02:00	3
2801	31	31	SALE	9	2026-10-02 18:15:00	3
2802	31	31	SALE	19	2026-10-03 14:06:00	3
2803	31	31	SALE	14	2026-10-04 10:32:00	3
2804	31	31	SALE	11	2026-10-05 16:07:00	3
2805	31	31	SALE	14	2026-10-06 17:04:00	3
2806	31	31	SALE	14	2026-10-07 12:13:00	3
2807	31	31	SALE	9	2026-10-08 14:36:00	3
2808	31	31	SALE	11	2026-10-09 14:53:00	3
2809	31	31	SALE	16	2026-10-10 19:26:00	3
2810	31	31	SALE	12	2026-10-11 10:41:00	3
2811	31	31	SALE	14	2026-10-12 15:56:00	3
2812	31	31	SALE	10	2026-10-13 13:09:00	3
2813	31	31	SALE	8	2026-10-14 09:20:00	3
2814	31	31	SALE	10	2026-10-15 18:50:00	3
2815	31	31	SALE	11	2026-10-16 14:21:00	3
2816	31	31	SALE	18	2026-10-17 15:57:00	3
2817	31	31	SALE	16	2026-10-18 19:23:00	3
2818	31	31	SALE	11	2026-10-19 16:18:00	3
2819	31	31	SALE	11	2026-10-20 18:01:00	3
2820	31	31	SALE	10	2026-10-21 11:23:00	3
2821	31	31	SALE	11	2026-10-22 09:18:00	3
2822	32	32	RECEIPT	1569	2026-07-25 08:00:00	2
2823	32	32	SALE	23	2026-07-25 12:16:00	3
2824	32	32	SALE	22	2026-07-26 16:09:00	3
2825	32	32	SALE	16	2026-07-27 16:52:00	3
2826	32	32	SALE	11	2026-07-28 11:46:00	3
2827	32	32	SALE	16	2026-07-29 16:18:00	3
2828	32	32	SALE	21	2026-07-30 11:12:00	3
2829	32	32	SALE	7	2026-07-31 19:56:00	3
2830	32	32	SALE	27	2026-08-01 10:33:00	3
2831	32	32	SALE	16	2026-08-02 20:47:00	3
2832	32	32	SALE	15	2026-08-03 12:00:00	3
2833	32	32	SALE	14	2026-08-04 15:04:00	3
2834	32	32	SALE	9	2026-08-05 16:35:00	3
2835	32	32	SALE	11	2026-08-06 18:13:00	3
2836	32	32	SALE	16	2026-08-07 20:11:00	3
2837	32	32	SALE	21	2026-08-08 09:26:00	3
2838	32	32	SALE	24	2026-08-09 20:16:00	3
2839	32	32	SALE	10	2026-08-10 18:24:00	3
2840	32	32	SALE	16	2026-08-11 19:37:00	3
2841	32	32	SALE	14	2026-08-12 12:40:00	3
2842	32	32	SALE	9	2026-08-13 14:30:00	3
2843	32	32	SALE	8	2026-08-14 17:42:00	3
2844	32	32	SALE	21	2026-08-15 11:56:00	3
2845	32	32	SALE	16	2026-08-16 13:53:00	3
2846	32	32	SALE	13	2026-08-17 12:56:00	3
2847	32	32	SALE	16	2026-08-18 13:42:00	3
2848	32	32	SALE	12	2026-08-19 16:31:00	3
2849	32	32	SALE	15	2026-08-20 19:25:00	3
2850	32	32	SALE	17	2026-08-21 18:22:00	3
2851	32	32	SALE	25	2026-08-22 17:30:00	3
2852	32	32	SALE	21	2026-08-23 13:06:00	3
2853	32	32	SALE	15	2026-08-24 12:07:00	3
2854	32	32	SALE	15	2026-08-25 13:26:00	3
2855	32	32	SALE	8	2026-08-26 16:20:00	3
2856	32	32	SALE	13	2026-08-27 12:42:00	3
2857	32	32	SALE	18	2026-08-28 15:07:00	3
2858	32	32	SALE	23	2026-08-29 11:29:00	3
2859	32	32	SALE	28	2026-08-30 14:42:00	3
2860	32	32	SALE	12	2026-08-31 10:22:00	3
2861	32	32	SALE	11	2026-09-01 20:25:00	3
2862	32	32	SALE	13	2026-09-02 20:08:00	3
2863	32	32	SALE	18	2026-09-03 16:53:00	3
2864	32	32	SALE	13	2026-09-04 16:38:00	3
2865	32	32	SALE	19	2026-09-05 15:43:00	3
2866	32	32	SALE	18	2026-09-06 12:01:00	3
2867	32	32	SALE	16	2026-09-07 13:17:00	3
2868	32	32	SALE	13	2026-09-08 17:13:00	3
2869	32	32	SALE	17	2026-09-09 15:03:00	3
2870	32	32	SALE	20	2026-09-10 17:49:00	3
2871	32	32	SALE	21	2026-09-11 14:16:00	3
2872	32	32	SALE	24	2026-09-12 19:20:00	3
2873	32	32	SALE	17	2026-09-13 15:25:00	3
2874	32	32	SALE	16	2026-09-14 16:27:00	3
2875	32	32	SALE	17	2026-09-15 15:16:00	3
2876	32	32	SALE	16	2026-09-16 09:17:00	3
2877	32	32	SALE	18	2026-09-17 16:46:00	3
2878	32	32	SALE	13	2026-09-18 12:21:00	3
2879	32	32	SALE	20	2026-09-19 19:52:00	3
2880	32	32	SALE	24	2026-09-20 09:19:00	3
2881	32	32	SALE	17	2026-09-21 16:26:00	3
2882	32	32	SALE	15	2026-09-22 12:36:00	3
2883	32	32	SALE	14	2026-09-23 11:34:00	3
2884	32	32	SALE	14	2026-09-24 12:49:00	3
2885	32	32	SALE	15	2026-09-25 19:07:00	3
2886	32	32	SALE	24	2026-09-26 18:39:00	3
2887	32	32	SALE	23	2026-09-27 14:08:00	3
2888	32	32	SALE	8	2026-09-28 18:34:00	3
2889	32	32	SALE	17	2026-09-29 09:46:00	3
2890	32	32	SALE	21	2026-09-30 09:51:00	3
2891	32	32	SALE	21	2026-10-01 15:05:00	3
2892	32	32	SALE	11	2026-10-02 20:21:00	3
2893	32	32	SALE	20	2026-10-03 14:49:00	3
2894	32	32	SALE	22	2026-10-04 17:04:00	3
2895	32	32	SALE	15	2026-10-05 19:03:00	3
2896	32	32	SALE	11	2026-10-06 17:13:00	3
2897	32	32	SALE	19	2026-10-07 14:34:00	3
2898	32	32	SALE	18	2026-10-08 12:10:00	3
2899	32	32	SALE	13	2026-10-09 17:25:00	3
2900	32	32	SALE	23	2026-10-10 20:14:00	3
2901	32	32	SALE	19	2026-10-11 13:51:00	3
2902	32	32	SALE	16	2026-10-12 11:58:00	3
2903	32	32	SALE	13	2026-10-13 14:21:00	3
2904	32	32	SALE	18	2026-10-14 15:13:00	3
2905	32	32	SALE	10	2026-10-15 17:46:00	3
2906	32	32	SALE	15	2026-10-16 12:00:00	3
2907	32	32	SALE	16	2026-10-17 09:54:00	3
2908	32	32	SALE	23	2026-10-18 09:48:00	3
2909	32	32	SALE	12	2026-10-19 17:06:00	3
2910	32	32	SALE	10	2026-10-20 17:25:00	3
2911	32	32	SALE	17	2026-10-21 16:02:00	3
2912	32	32	SALE	15	2026-10-22 11:18:00	3
2913	33	33	RECEIPT	2890	2026-07-25 08:00:00	2
2914	33	33	SALE	32	2026-07-25 19:07:00	3
2915	33	33	SALE	39	2026-07-26 17:57:00	3
2916	33	33	SALE	24	2026-07-27 15:41:00	3
2917	33	33	SALE	16	2026-07-28 14:11:00	3
2918	33	33	SALE	23	2026-07-29 09:55:00	3
2919	33	33	SALE	25	2026-07-30 14:54:00	3
2920	33	33	SALE	65	2026-07-31 16:49:00	3
2921	33	33	SALE	28	2026-08-01 19:22:00	3
2922	33	33	SALE	34	2026-08-02 20:27:00	3
2923	33	33	SALE	20	2026-08-03 12:39:00	3
2924	33	33	SALE	21	2026-08-04 17:56:00	3
2925	33	33	SALE	28	2026-08-05 12:24:00	3
2926	33	33	SALE	24	2026-08-06 14:11:00	3
2927	33	33	SALE	26	2026-08-07 20:00:00	3
2928	33	33	SALE	41	2026-08-08 12:28:00	3
2929	33	33	SALE	39	2026-08-09 14:33:00	3
2930	33	33	SALE	50	2026-08-10 12:00:00	3
2931	33	33	SALE	22	2026-08-11 18:19:00	3
2932	33	33	SALE	19	2026-08-12 14:06:00	3
2933	33	33	SALE	27	2026-08-13 14:58:00	3
2934	33	33	SALE	28	2026-08-14 13:32:00	3
2935	33	33	SALE	31	2026-08-15 09:38:00	3
2936	33	33	SALE	29	2026-08-16 13:02:00	3
2937	33	33	SALE	30	2026-08-17 19:17:00	3
2938	33	33	SALE	27	2026-08-18 19:30:00	3
2939	33	33	SALE	31	2026-08-19 15:02:00	3
2940	33	33	SALE	27	2026-08-20 20:45:00	3
2941	33	33	SALE	28	2026-08-21 13:17:00	3
2942	33	33	SALE	33	2026-08-22 19:03:00	3
2943	33	33	SALE	39	2026-08-23 18:52:00	3
2944	33	33	SALE	25	2026-08-24 09:55:00	3
2945	33	33	SALE	26	2026-08-25 20:59:00	3
2946	33	33	SALE	30	2026-08-26 16:38:00	3
2947	33	33	SALE	23	2026-08-27 19:29:00	3
2948	33	33	SALE	19	2026-08-28 16:11:00	3
2949	33	33	SALE	30	2026-08-29 16:47:00	3
2950	33	33	SALE	41	2026-08-30 19:48:00	3
2951	33	33	SALE	12	2026-08-31 17:51:00	3
2952	33	33	SALE	22	2026-09-01 10:02:00	3
2953	33	33	SALE	19	2026-09-02 14:01:00	3
2954	33	33	SALE	23	2026-09-03 18:57:00	3
2955	33	33	SALE	20	2026-09-04 20:09:00	3
2956	33	33	SALE	28	2026-09-05 20:47:00	3
2957	33	33	SALE	33	2026-09-06 11:55:00	3
2958	33	33	SALE	19	2026-09-07 11:05:00	3
2959	33	33	SALE	22	2026-09-08 15:53:00	3
2960	33	33	SALE	20	2026-09-09 10:03:00	3
2961	33	33	SALE	33	2026-09-10 16:40:00	3
2962	33	33	SALE	20	2026-09-11 20:03:00	3
2963	33	33	SALE	28	2026-09-12 14:06:00	3
2964	33	33	SALE	25	2026-09-13 17:17:00	3
2965	33	33	SALE	18	2026-09-14 12:41:00	3
2966	33	33	SALE	13	2026-09-15 18:47:00	3
2967	33	33	SALE	25	2026-09-16 09:21:00	3
2968	33	33	SALE	24	2026-09-17 19:54:00	3
2969	33	33	SALE	21	2026-09-18 14:57:00	3
2970	33	33	SALE	28	2026-09-19 20:10:00	3
2971	33	33	SALE	36	2026-09-20 18:46:00	3
2972	33	33	SALE	26	2026-09-21 14:33:00	3
2973	33	33	SALE	30	2026-09-22 09:42:00	3
2974	33	33	SALE	28	2026-09-23 15:26:00	3
2975	33	33	SALE	25	2026-09-24 19:42:00	3
2976	33	33	SALE	20	2026-09-25 09:04:00	3
2977	33	33	SALE	33	2026-09-26 12:52:00	3
2978	33	33	SALE	38	2026-09-27 17:09:00	3
2979	33	33	SALE	19	2026-09-28 20:17:00	3
2980	33	33	SALE	20	2026-09-29 10:11:00	3
2981	33	33	SALE	25	2026-09-30 16:02:00	3
2982	33	33	SALE	25	2026-10-01 13:38:00	3
2983	33	33	SALE	24	2026-10-02 12:44:00	3
2984	33	33	SALE	38	2026-10-03 17:26:00	3
2985	33	33	SALE	38	2026-10-04 11:40:00	3
2986	33	33	SALE	24	2026-10-05 20:53:00	3
2987	33	33	SALE	17	2026-10-06 09:19:00	3
2988	33	33	SALE	28	2026-10-07 13:35:00	3
2989	33	33	SALE	18	2026-10-08 14:07:00	3
2990	33	33	SALE	26	2026-10-09 14:29:00	3
2991	33	33	SALE	20	2026-10-10 18:53:00	3
2992	33	33	SALE	34	2026-10-11 20:05:00	3
2993	33	33	SALE	20	2026-10-12 18:59:00	3
2994	33	33	SALE	18	2026-10-13 16:05:00	3
2995	33	33	SALE	23	2026-10-14 10:58:00	3
2996	33	33	SALE	21	2026-10-15 10:11:00	3
2997	33	33	SALE	23	2026-10-16 20:05:00	3
2998	33	33	SALE	28	2026-10-17 11:20:00	3
2999	33	33	SALE	33	2026-10-18 18:40:00	3
3000	33	33	SALE	29	2026-10-19 09:49:00	3
3001	33	33	SALE	13	2026-10-20 11:50:00	3
3002	33	33	SALE	21	2026-10-21 09:13:00	3
3003	33	33	SALE	14	2026-10-22 19:23:00	3
3004	34	34	RECEIPT	1112	2026-07-25 08:00:00	2
3005	34	34	SALE	16	2026-07-25 16:18:00	3
3006	34	34	SALE	10	2026-07-26 09:07:00	3
3007	34	34	SALE	11	2026-07-27 16:29:00	3
3008	34	34	SALE	7	2026-07-28 14:03:00	3
3009	34	34	SALE	8	2026-07-29 18:43:00	3
3010	34	34	SALE	10	2026-07-30 14:16:00	3
3011	34	34	SALE	6	2026-07-31 15:21:00	3
3012	34	34	SALE	14	2026-08-01 19:18:00	3
3013	34	34	SALE	11	2026-08-02 09:34:00	3
3014	34	34	SALE	9	2026-08-03 13:11:00	3
3015	34	34	SALE	9	2026-08-04 13:22:00	3
3016	34	34	SALE	7	2026-08-05 15:01:00	3
3017	34	34	SALE	11	2026-08-06 16:20:00	3
3018	34	34	SALE	13	2026-08-07 13:40:00	3
3019	34	34	SALE	15	2026-08-08 09:38:00	3
3020	34	34	SALE	13	2026-08-09 10:22:00	3
3021	34	34	SALE	6	2026-08-10 20:02:00	3
3022	34	34	SALE	13	2026-08-11 17:47:00	3
3023	34	34	SALE	9	2026-08-12 15:15:00	3
3024	34	34	SALE	11	2026-08-13 11:05:00	3
3025	34	34	SALE	9	2026-08-14 17:06:00	3
3026	34	34	SALE	17	2026-08-15 11:46:00	3
3027	34	34	SALE	12	2026-08-16 11:40:00	3
3028	34	34	SALE	11	2026-08-17 16:27:00	3
3029	34	34	SALE	9	2026-08-18 13:22:00	3
3030	34	34	SALE	10	2026-08-19 16:44:00	3
3031	34	34	SALE	10	2026-08-20 18:15:00	3
3032	34	34	SALE	11	2026-08-21 20:52:00	3
3033	34	34	SALE	11	2026-08-22 17:36:00	3
3034	34	34	SALE	14	2026-08-23 16:02:00	3
3035	34	34	SALE	7	2026-08-24 10:20:00	3
3036	34	34	SALE	7	2026-08-25 14:02:00	3
3037	34	34	SALE	8	2026-08-26 11:38:00	3
3038	34	34	SALE	9	2026-08-27 20:40:00	3
3039	34	34	SALE	7	2026-08-28 10:24:00	3
3040	34	34	SALE	14	2026-08-29 17:46:00	3
3041	34	34	SALE	14	2026-08-30 10:21:00	3
3042	34	34	SALE	9	2026-08-31 19:47:00	3
3043	34	34	SALE	7	2026-09-01 13:27:00	3
3044	34	34	SALE	8	2026-09-02 15:01:00	3
3045	34	34	SALE	8	2026-09-03 11:47:00	3
3046	34	34	SALE	11	2026-09-04 13:46:00	3
3047	34	34	SALE	13	2026-09-05 19:47:00	3
3048	34	34	SALE	13	2026-09-06 10:53:00	3
3049	34	34	SALE	12	2026-09-07 15:07:00	3
3050	34	34	SALE	11	2026-09-08 12:36:00	3
3051	34	34	SALE	7	2026-09-09 13:19:00	3
3052	34	34	SALE	10	2026-09-10 18:32:00	3
3053	34	34	SALE	10	2026-09-11 17:54:00	3
3054	34	34	SALE	15	2026-09-12 12:44:00	3
3055	34	34	SALE	14	2026-09-13 09:23:00	3
3056	34	34	SALE	24	2026-09-14 18:30:00	3
3057	34	34	SALE	11	2026-09-15 12:48:00	3
3058	34	34	SALE	10	2026-09-16 15:17:00	3
3059	34	34	SALE	7	2026-09-17 20:44:00	3
3060	34	34	SALE	9	2026-09-18 11:17:00	3
3061	34	34	SALE	12	2026-09-19 17:42:00	3
3062	34	34	SALE	13	2026-09-20 09:38:00	3
3063	34	34	SALE	8	2026-09-21 15:58:00	3
3064	34	34	SALE	12	2026-09-22 11:43:00	3
3065	34	34	SALE	7	2026-09-23 13:17:00	3
3066	34	34	SALE	9	2026-09-24 09:26:00	3
3067	34	34	SALE	13	2026-09-25 12:01:00	3
3068	34	34	SALE	13	2026-09-26 15:42:00	3
3069	34	34	SALE	15	2026-09-27 11:17:00	3
3070	34	34	SALE	9	2026-09-28 13:29:00	3
3071	34	34	SALE	9	2026-09-29 18:50:00	3
3072	34	34	SALE	11	2026-09-30 19:20:00	3
3073	34	34	SALE	10	2026-10-01 10:14:00	3
3074	34	34	SALE	10	2026-10-02 12:01:00	3
3075	34	34	SALE	11	2026-10-03 20:20:00	3
3076	34	34	SALE	12	2026-10-04 12:04:00	3
3077	34	34	SALE	7	2026-10-05 18:18:00	3
3078	34	34	SALE	10	2026-10-06 20:45:00	3
3079	34	34	SALE	7	2026-10-07 18:52:00	3
3080	34	34	SALE	11	2026-10-08 16:37:00	3
3081	34	34	SALE	9	2026-10-09 15:40:00	3
3082	34	34	SALE	12	2026-10-10 18:21:00	3
3083	34	34	SALE	10	2026-10-11 17:24:00	3
3084	34	34	SALE	7	2026-10-12 16:59:00	3
3085	34	34	SALE	6	2026-10-13 17:00:00	3
3086	34	34	SALE	10	2026-10-14 14:21:00	3
3087	34	34	SALE	11	2026-10-15 14:22:00	3
3088	34	34	SALE	8	2026-10-16 16:09:00	3
3089	34	34	SALE	14	2026-10-17 16:54:00	3
3090	34	34	SALE	12	2026-10-18 20:31:00	3
3091	34	34	SALE	29	2026-10-19 12:34:00	3
3092	34	34	SALE	8	2026-10-20 20:10:00	3
3093	34	34	SALE	9	2026-10-21 19:24:00	3
3094	34	34	SALE	11	2026-10-22 13:25:00	3
3095	35	35	RECEIPT	2276	2026-07-25 08:00:00	2
3096	35	35	SALE	31	2026-07-25 13:38:00	3
3097	35	35	SALE	19	2026-07-26 20:50:00	3
3098	35	35	SALE	22	2026-07-27 10:41:00	3
3099	35	35	SALE	30	2026-07-28 12:22:00	3
3100	35	35	SALE	17	2026-07-29 16:29:00	3
3101	35	35	SALE	24	2026-07-30 18:58:00	3
3102	35	35	SALE	21	2026-07-31 19:58:00	3
3103	35	35	SALE	32	2026-08-01 09:53:00	3
3104	35	35	SALE	24	2026-08-02 20:54:00	3
3105	35	35	SALE	17	2026-08-03 17:57:00	3
3106	35	35	SALE	23	2026-08-04 12:47:00	3
3107	35	35	SALE	23	2026-08-05 12:23:00	3
3108	35	35	SALE	21	2026-08-06 19:02:00	3
3109	35	35	SALE	31	2026-08-07 15:40:00	3
3110	35	35	SALE	26	2026-08-08 10:21:00	3
3111	35	35	SALE	20	2026-08-09 17:04:00	3
3112	35	35	SALE	15	2026-08-10 13:35:00	3
3113	35	35	SALE	22	2026-08-11 17:54:00	3
3114	35	35	SALE	25	2026-08-12 20:34:00	3
3115	35	35	SALE	24	2026-08-13 10:51:00	3
3116	35	35	SALE	17	2026-08-14 09:28:00	3
3117	35	35	SALE	32	2026-08-15 18:33:00	3
3118	35	35	SALE	28	2026-08-16 12:15:00	3
3119	35	35	SALE	15	2026-08-17 13:51:00	3
3120	35	35	SALE	18	2026-08-18 20:11:00	3
3121	35	35	SALE	24	2026-08-19 20:59:00	3
3122	35	35	SALE	23	2026-08-20 19:54:00	3
3123	35	35	SALE	26	2026-08-21 12:14:00	3
3124	35	35	SALE	24	2026-08-22 20:45:00	3
3125	35	35	SALE	28	2026-08-23 16:11:00	3
3126	35	35	SALE	24	2026-08-24 09:38:00	3
3127	35	35	SALE	19	2026-08-25 13:35:00	3
3128	35	35	SALE	18	2026-08-26 13:05:00	3
3129	35	35	SALE	22	2026-08-27 20:12:00	3
3130	35	35	SALE	22	2026-08-28 20:53:00	3
3131	35	35	SALE	30	2026-08-29 10:57:00	3
3132	35	35	SALE	32	2026-08-30 11:33:00	3
3133	35	35	SALE	13	2026-08-31 13:03:00	3
3134	35	35	SALE	21	2026-09-01 12:14:00	3
3135	35	35	SALE	17	2026-09-02 12:37:00	3
3136	35	35	SALE	18	2026-09-03 18:30:00	3
3137	35	35	SALE	22	2026-09-04 16:06:00	3
3138	35	35	SALE	27	2026-09-05 17:56:00	3
3139	35	35	SALE	33	2026-09-06 09:20:00	3
3140	35	35	SALE	17	2026-09-07 19:04:00	3
3141	35	35	SALE	19	2026-09-08 12:30:00	3
3142	35	35	SALE	21	2026-09-09 10:28:00	3
3143	35	35	SALE	18	2026-09-10 10:30:00	3
3144	35	35	SALE	20	2026-09-11 12:06:00	3
3145	35	35	SALE	28	2026-09-12 17:37:00	3
3146	35	35	SALE	32	2026-09-13 12:38:00	3
3147	35	35	SALE	21	2026-09-14 16:19:00	3
3148	35	35	SALE	24	2026-09-15 18:00:00	3
3149	35	35	SALE	24	2026-09-16 18:27:00	3
3150	35	35	SALE	23	2026-09-17 10:46:00	3
3151	35	35	SALE	20	2026-09-18 16:49:00	3
3152	35	35	SALE	29	2026-09-19 19:12:00	3
3153	35	35	SALE	22	2026-09-20 18:51:00	3
3154	35	35	SALE	17	2026-09-21 19:39:00	3
3155	35	35	SALE	16	2026-09-22 16:00:00	3
3156	35	35	SALE	18	2026-09-23 13:48:00	3
3157	35	35	SALE	26	2026-09-24 15:38:00	3
3158	35	35	SALE	21	2026-09-25 13:31:00	3
3159	35	35	SALE	32	2026-09-26 19:11:00	3
3160	35	35	SALE	30	2026-09-27 14:32:00	3
3161	35	35	SALE	22	2026-09-28 16:32:00	3
3162	35	35	SALE	16	2026-09-29 13:41:00	3
3163	35	35	SALE	19	2026-09-30 13:16:00	3
3164	35	35	SALE	13	2026-10-01 17:15:00	3
3165	35	35	SALE	21	2026-10-02 14:17:00	3
3166	35	35	SALE	27	2026-10-03 19:35:00	3
3167	35	35	SALE	23	2026-10-04 17:19:00	3
3168	35	35	SALE	17	2026-10-05 19:28:00	3
3169	35	35	SALE	21	2026-10-06 10:48:00	3
3170	35	35	SALE	16	2026-10-07 11:31:00	3
3171	35	35	SALE	16	2026-10-08 09:20:00	3
3172	35	35	SALE	19	2026-10-09 17:30:00	3
3173	35	35	SALE	20	2026-10-10 16:10:00	3
3174	35	35	SALE	30	2026-10-11 11:04:00	3
3175	35	35	SALE	19	2026-10-12 15:43:00	3
3176	35	35	SALE	19	2026-10-13 13:06:00	3
3177	35	35	SALE	25	2026-10-14 16:21:00	3
3178	35	35	SALE	15	2026-10-15 19:43:00	3
3179	35	35	SALE	22	2026-10-16 17:52:00	3
3180	35	35	SALE	27	2026-10-17 11:12:00	3
3181	35	35	SALE	25	2026-10-18 10:48:00	3
3182	35	35	SALE	21	2026-10-19 12:13:00	3
3183	35	35	SALE	23	2026-10-20 13:32:00	3
3184	35	35	SALE	28	2026-10-21 13:20:00	3
3185	35	35	SALE	20	2026-10-22 17:30:00	3
3186	36	36	RECEIPT	1040	2026-07-25 08:00:00	2
3187	36	36	SALE	10	2026-07-25 20:20:00	3
3188	36	36	SALE	13	2026-07-26 15:12:00	3
3189	36	36	SALE	8	2026-07-27 12:05:00	3
3190	36	36	SALE	5	2026-07-28 17:23:00	3
3191	36	36	SALE	10	2026-07-29 16:16:00	3
3192	36	36	SALE	11	2026-07-30 17:07:00	3
3193	36	36	SALE	9	2026-07-31 16:01:00	3
3194	36	36	SALE	9	2026-08-01 09:24:00	3
3195	36	36	SALE	11	2026-08-02 15:25:00	3
3196	36	36	SALE	9	2026-08-03 10:22:00	3
3197	36	36	SALE	8	2026-08-04 14:19:00	3
3198	36	36	SALE	6	2026-08-05 10:27:00	3
3199	36	36	SALE	6	2026-08-06 19:19:00	3
3200	36	36	SALE	9	2026-08-07 12:44:00	3
3201	36	36	SALE	12	2026-08-08 10:41:00	3
3202	36	36	SALE	6	2026-08-09 19:51:00	3
3203	36	36	SALE	9	2026-08-10 15:56:00	3
3204	36	36	SALE	10	2026-08-11 16:01:00	3
3205	36	36	SALE	7	2026-08-12 13:46:00	3
3206	36	36	SALE	11	2026-08-13 19:57:00	3
3207	36	36	SALE	8	2026-08-14 14:02:00	3
3208	36	36	SALE	13	2026-08-15 11:54:00	3
3209	36	36	SALE	10	2026-08-16 12:11:00	3
3210	36	36	SALE	10	2026-08-17 18:00:00	3
3211	36	36	SALE	8	2026-08-18 11:33:00	3
3212	36	36	SALE	8	2026-08-19 11:08:00	3
3213	36	36	SALE	10	2026-08-20 20:30:00	3
3214	36	36	SALE	7	2026-08-21 09:03:00	3
3215	36	36	SALE	13	2026-08-22 18:51:00	3
3216	36	36	SALE	12	2026-08-23 12:55:00	3
3217	36	36	SALE	9	2026-08-24 20:42:00	3
3218	36	36	SALE	9	2026-08-25 13:23:00	3
3219	36	36	SALE	8	2026-08-26 18:26:00	3
3220	36	36	SALE	6	2026-08-27 11:26:00	3
3221	36	36	SALE	8	2026-08-28 11:11:00	3
3222	36	36	SALE	12	2026-08-29 17:09:00	3
3223	36	36	SALE	11	2026-08-30 20:51:00	3
3224	36	36	SALE	10	2026-08-31 19:11:00	3
3225	36	36	SALE	8	2026-09-01 14:56:00	3
3226	36	36	SALE	7	2026-09-02 10:50:00	3
3227	36	36	SALE	7	2026-09-03 11:01:00	3
3228	36	36	SALE	11	2026-09-04 16:13:00	3
3229	36	36	SALE	13	2026-09-05 13:25:00	3
3230	36	36	SALE	13	2026-09-06 19:23:00	3
3231	36	36	SALE	8	2026-09-07 13:39:00	3
3232	36	36	SALE	7	2026-09-08 14:01:00	3
3233	36	36	SALE	9	2026-09-09 09:21:00	3
3234	36	36	SALE	9	2026-09-10 09:56:00	3
3235	36	36	SALE	10	2026-09-11 16:02:00	3
3236	36	36	SALE	29	2026-09-12 20:55:00	3
3237	36	36	SALE	8	2026-09-13 11:58:00	3
3238	36	36	SALE	8	2026-09-14 15:02:00	3
3239	36	36	SALE	6	2026-09-15 17:24:00	3
3240	36	36	SALE	7	2026-09-16 18:46:00	3
3241	36	36	SALE	11	2026-09-17 17:10:00	3
3242	36	36	SALE	8	2026-09-18 11:06:00	3
3243	36	36	SALE	15	2026-09-19 09:22:00	3
3244	36	36	SALE	14	2026-09-20 12:05:00	3
3245	36	36	SALE	8	2026-09-21 15:04:00	3
3246	36	36	SALE	6	2026-09-22 10:30:00	3
3247	36	36	SALE	10	2026-09-23 16:26:00	3
3248	36	36	SALE	6	2026-09-24 17:28:00	3
3249	36	36	SALE	7	2026-09-25 11:54:00	3
3250	36	36	SALE	10	2026-09-26 18:51:00	3
3251	36	36	SALE	37	2026-09-27 19:00:00	3
3252	36	36	SALE	18	2026-09-28 13:30:00	3
3253	36	36	SALE	7	2026-09-29 16:57:00	3
3254	36	36	SALE	9	2026-09-30 13:08:00	3
3255	36	36	SALE	7	2026-10-01 14:42:00	3
3256	36	36	SALE	10	2026-10-02 17:23:00	3
3257	36	36	SALE	9	2026-10-03 18:42:00	3
3258	36	36	SALE	13	2026-10-04 20:06:00	3
3259	36	36	SALE	8	2026-10-05 16:31:00	3
3260	36	36	SALE	9	2026-10-06 20:53:00	3
3261	36	36	SALE	10	2026-10-07 18:12:00	3
3262	36	36	SALE	6	2026-10-08 11:14:00	3
3263	36	36	SALE	7	2026-10-09 17:08:00	3
3264	36	36	SALE	12	2026-10-10 11:14:00	3
3265	36	36	SALE	11	2026-10-11 19:05:00	3
3266	36	36	SALE	12	2026-10-12 20:06:00	3
3267	36	36	SALE	10	2026-10-13 20:25:00	3
3268	36	36	SALE	11	2026-10-14 13:56:00	3
3269	36	36	SALE	7	2026-10-15 18:06:00	3
3270	36	36	SALE	9	2026-10-16 12:14:00	3
3271	36	36	SALE	9	2026-10-17 13:11:00	3
3272	36	36	SALE	12	2026-10-18 20:42:00	3
3273	36	36	SALE	9	2026-10-19 13:21:00	3
3274	36	36	SALE	9	2026-10-20 20:29:00	3
3275	36	36	SALE	10	2026-10-21 19:37:00	3
3276	36	36	SALE	10	2026-10-22 17:33:00	3
3277	37	37	RECEIPT	1865	2026-07-25 08:00:00	2
3278	37	37	SALE	25	2026-07-25 16:36:00	3
3279	37	37	SALE	17	2026-07-26 17:02:00	3
3280	37	37	SALE	9	2026-07-27 15:52:00	3
3281	37	37	SALE	12	2026-07-28 19:47:00	3
3282	37	37	SALE	14	2026-07-29 15:42:00	3
3283	37	37	SALE	16	2026-07-30 09:13:00	3
3284	37	37	SALE	15	2026-07-31 18:11:00	3
3285	37	37	SALE	21	2026-08-01 09:40:00	3
3286	37	37	SALE	18	2026-08-02 14:06:00	3
3287	37	37	SALE	15	2026-08-03 13:58:00	3
3288	37	37	SALE	12	2026-08-04 15:51:00	3
3289	37	37	SALE	13	2026-08-05 09:46:00	3
3290	37	37	SALE	14	2026-08-06 16:54:00	3
3291	37	37	SALE	15	2026-08-07 13:22:00	3
3292	37	37	SALE	19	2026-08-08 19:22:00	3
3293	37	37	SALE	27	2026-08-09 14:15:00	3
3294	37	37	SALE	11	2026-08-10 13:28:00	3
3295	37	37	SALE	14	2026-08-11 09:20:00	3
3296	37	37	SALE	14	2026-08-12 16:44:00	3
3297	37	37	SALE	15	2026-08-13 19:16:00	3
3298	37	37	SALE	17	2026-08-14 11:13:00	3
3299	37	37	SALE	21	2026-08-15 17:49:00	3
3300	37	37	SALE	19	2026-08-16 17:41:00	3
3301	37	37	SALE	21	2026-08-17 14:47:00	3
3302	37	37	SALE	16	2026-08-18 15:48:00	3
3303	37	37	SALE	15	2026-08-19 14:49:00	3
3304	37	37	SALE	9	2026-08-20 11:54:00	3
3305	37	37	SALE	19	2026-08-21 16:54:00	3
3306	37	37	SALE	22	2026-08-22 10:21:00	3
3307	37	37	SALE	21	2026-08-23 14:39:00	3
3308	37	37	SALE	18	2026-08-24 17:47:00	3
3309	37	37	SALE	20	2026-08-25 12:20:00	3
3310	37	37	SALE	14	2026-08-26 13:06:00	3
3311	37	37	SALE	17	2026-08-27 20:05:00	3
3312	37	37	SALE	14	2026-08-28 19:25:00	3
3313	37	37	SALE	22	2026-08-29 14:39:00	3
3314	37	37	SALE	22	2026-08-30 16:40:00	3
3315	37	37	SALE	13	2026-08-31 11:48:00	3
3316	37	37	SALE	17	2026-09-01 15:12:00	3
3317	37	37	SALE	13	2026-09-02 13:54:00	3
3318	37	37	SALE	13	2026-09-03 20:31:00	3
3319	37	37	SALE	21	2026-09-04 14:21:00	3
3320	37	37	SALE	59	2026-09-05 16:57:00	3
3321	37	37	SALE	27	2026-09-06 14:48:00	3
3322	37	37	SALE	19	2026-09-07 11:10:00	3
3323	37	37	SALE	13	2026-09-08 14:01:00	3
3324	37	37	SALE	14	2026-09-09 10:12:00	3
3325	37	37	SALE	16	2026-09-10 18:19:00	3
3326	37	37	SALE	18	2026-09-11 17:44:00	3
3327	37	37	SALE	15	2026-09-12 19:35:00	3
3328	37	37	SALE	23	2026-09-13 13:48:00	3
3329	37	37	SALE	20	2026-09-14 17:34:00	3
3330	37	37	SALE	14	2026-09-15 11:25:00	3
3331	37	37	SALE	21	2026-09-16 18:44:00	3
3332	37	37	SALE	17	2026-09-17 10:12:00	3
3333	37	37	SALE	14	2026-09-18 10:05:00	3
3334	37	37	SALE	23	2026-09-19 20:38:00	3
3335	37	37	SALE	20	2026-09-20 19:25:00	3
3336	37	37	SALE	11	2026-09-21 13:09:00	3
3337	37	37	SALE	16	2026-09-22 20:21:00	3
3338	37	37	SALE	15	2026-09-23 17:22:00	3
3339	37	37	SALE	12	2026-09-24 15:08:00	3
3340	37	37	SALE	17	2026-09-25 15:06:00	3
3341	37	37	SALE	21	2026-09-26 20:52:00	3
3342	37	37	SALE	25	2026-09-27 13:39:00	3
3343	37	37	SALE	17	2026-09-28 18:05:00	3
3344	37	37	SALE	13	2026-09-29 14:14:00	3
3345	37	37	SALE	10	2026-09-30 16:52:00	3
3346	37	37	SALE	23	2026-10-01 09:15:00	3
3347	37	37	SALE	21	2026-10-02 17:09:00	3
3348	37	37	SALE	24	2026-10-03 19:17:00	3
3349	37	37	SALE	19	2026-10-04 09:31:00	3
3350	37	37	SALE	11	2026-10-05 12:53:00	3
3351	37	37	SALE	10	2026-10-06 20:14:00	3
3352	37	37	SALE	15	2026-10-07 12:56:00	3
3353	37	37	SALE	17	2026-10-08 12:28:00	3
3354	37	37	SALE	19	2026-10-09 19:51:00	3
3355	37	37	SALE	12	2026-10-10 12:09:00	3
3356	37	37	SALE	16	2026-10-11 09:18:00	3
3357	37	37	SALE	15	2026-10-12 12:01:00	3
3358	37	37	SALE	16	2026-10-13 18:30:00	3
3359	37	37	SALE	10	2026-10-14 16:26:00	3
3360	37	37	SALE	12	2026-10-15 17:35:00	3
3361	37	37	SALE	18	2026-10-16 18:12:00	3
3362	37	37	SALE	17	2026-10-17 15:11:00	3
3363	37	37	SALE	18	2026-10-18 17:37:00	3
3364	37	37	SALE	15	2026-10-19 15:40:00	3
3365	37	37	SALE	12	2026-10-20 18:56:00	3
3366	37	37	SALE	12	2026-10-21 15:47:00	3
3367	37	37	SALE	16	2026-10-22 13:45:00	3
3368	38	38	RECEIPT	1176	2026-07-25 08:00:00	2
3369	38	38	SALE	11	2026-07-25 15:12:00	3
3370	38	38	SALE	15	2026-07-26 14:34:00	3
3371	38	38	SALE	9	2026-07-27 09:52:00	3
3372	38	38	SALE	11	2026-07-28 19:55:00	3
3373	38	38	SALE	8	2026-07-29 15:47:00	3
3374	38	38	SALE	12	2026-07-30 17:33:00	3
3375	38	38	SALE	8	2026-07-31 11:32:00	3
3376	38	38	SALE	13	2026-08-01 14:43:00	3
3377	38	38	SALE	15	2026-08-02 20:02:00	3
3378	38	38	SALE	11	2026-08-03 12:06:00	3
3379	38	38	SALE	8	2026-08-04 16:11:00	3
3380	38	38	SALE	4	2026-08-05 12:45:00	3
3381	38	38	SALE	9	2026-08-06 14:04:00	3
3382	38	38	SALE	12	2026-08-07 20:13:00	3
3383	38	38	SALE	18	2026-08-08 16:13:00	3
3384	38	38	SALE	15	2026-08-09 18:40:00	3
3385	38	38	SALE	11	2026-08-10 18:00:00	3
3386	38	38	SALE	8	2026-08-11 09:59:00	3
3387	38	38	SALE	6	2026-08-12 15:13:00	3
3388	38	38	SALE	13	2026-08-13 20:07:00	3
3389	38	38	SALE	9	2026-08-14 13:00:00	3
3390	38	38	SALE	12	2026-08-15 12:42:00	3
3391	38	38	SALE	10	2026-08-16 14:11:00	3
3392	38	38	SALE	11	2026-08-17 15:52:00	3
3393	38	38	SALE	9	2026-08-18 12:23:00	3
3394	38	38	SALE	10	2026-08-19 15:02:00	3
3395	38	38	SALE	6	2026-08-20 11:09:00	3
3396	38	38	SALE	11	2026-08-21 18:15:00	3
3397	38	38	SALE	14	2026-08-22 18:42:00	3
3398	38	38	SALE	13	2026-08-23 13:56:00	3
3399	38	38	SALE	10	2026-08-24 15:43:00	3
3400	38	38	SALE	9	2026-08-25 18:45:00	3
3401	38	38	SALE	11	2026-08-26 19:19:00	3
3402	38	38	SALE	14	2026-08-27 12:56:00	3
3403	38	38	SALE	9	2026-08-28 19:47:00	3
3404	38	38	SALE	13	2026-08-29 13:26:00	3
3405	38	38	SALE	10	2026-08-30 20:00:00	3
3406	38	38	SALE	11	2026-08-31 15:52:00	3
3407	38	38	SALE	8	2026-09-01 15:24:00	3
3408	38	38	SALE	10	2026-09-02 13:53:00	3
3409	38	38	SALE	9	2026-09-03 12:52:00	3
3410	38	38	SALE	10	2026-09-04 16:16:00	3
3411	38	38	SALE	12	2026-09-05 18:00:00	3
3412	38	38	SALE	14	2026-09-06 19:44:00	3
3413	38	38	SALE	8	2026-09-07 15:02:00	3
3414	38	38	SALE	9	2026-09-08 20:49:00	3
3415	38	38	SALE	11	2026-09-09 16:08:00	3
3416	38	38	SALE	10	2026-09-10 19:44:00	3
3417	38	38	SALE	33	2026-09-11 12:04:00	3
3418	38	38	SALE	12	2026-09-12 19:07:00	3
3419	38	38	SALE	12	2026-09-13 10:10:00	3
3420	38	38	SALE	9	2026-09-14 16:04:00	3
3421	38	38	SALE	7	2026-09-15 11:34:00	3
3422	38	38	SALE	9	2026-09-16 14:10:00	3
3423	38	38	SALE	9	2026-09-17 20:16:00	3
3424	38	38	SALE	8	2026-09-18 19:45:00	3
3425	38	38	SALE	14	2026-09-19 20:25:00	3
3426	38	38	SALE	11	2026-09-20 13:34:00	3
3427	38	38	SALE	6	2026-09-21 13:18:00	3
3428	38	38	SALE	6	2026-09-22 18:16:00	3
3429	38	38	SALE	12	2026-09-23 10:48:00	3
3430	38	38	SALE	12	2026-09-24 10:25:00	3
3431	38	38	SALE	8	2026-09-25 12:05:00	3
3432	38	38	SALE	10	2026-09-26 17:54:00	3
3433	38	38	SALE	11	2026-09-27 16:12:00	3
3434	38	38	SALE	8	2026-09-28 11:33:00	3
3435	38	38	SALE	11	2026-09-29 09:30:00	3
3436	38	38	SALE	6	2026-09-30 16:06:00	3
3437	38	38	SALE	10	2026-10-01 10:14:00	3
3438	38	38	SALE	10	2026-10-02 09:53:00	3
3439	38	38	SALE	13	2026-10-03 15:11:00	3
3440	38	38	SALE	13	2026-10-04 10:48:00	3
3441	38	38	SALE	10	2026-10-05 20:51:00	3
3442	38	38	SALE	7	2026-10-06 10:15:00	3
3443	38	38	SALE	9	2026-10-07 15:39:00	3
3444	38	38	SALE	8	2026-10-08 14:28:00	3
3445	38	38	SALE	6	2026-10-09 20:09:00	3
3446	38	38	SALE	12	2026-10-10 16:38:00	3
3447	38	38	SALE	14	2026-10-11 09:42:00	3
3448	38	38	SALE	11	2026-10-12 17:49:00	3
3449	38	38	SALE	8	2026-10-13 12:49:00	3
3450	38	38	SALE	10	2026-10-14 12:46:00	3
3451	38	38	SALE	8	2026-10-15 14:02:00	3
3452	38	38	SALE	11	2026-10-16 18:00:00	3
3453	38	38	SALE	12	2026-10-17 11:21:00	3
3454	38	38	SALE	16	2026-10-18 13:58:00	3
3455	38	38	SALE	12	2026-10-19 11:22:00	3
3456	38	38	SALE	11	2026-10-20 16:12:00	3
3457	38	38	SALE	10	2026-10-21 19:03:00	3
3458	38	38	SALE	10	2026-10-22 15:24:00	3
3459	39	39	RECEIPT	824	2026-07-25 08:00:00	2
3460	39	39	SALE	9	2026-07-25 13:16:00	3
3461	39	39	SALE	10	2026-07-26 16:27:00	3
3462	39	39	SALE	4	2026-07-27 14:02:00	3
3463	39	39	SALE	8	2026-07-28 13:47:00	3
3464	39	39	SALE	5	2026-07-29 19:29:00	3
3465	39	39	SALE	7	2026-07-30 19:05:00	3
3466	39	39	SALE	9	2026-07-31 14:35:00	3
3467	39	39	SALE	11	2026-08-01 09:08:00	3
3468	39	39	SALE	11	2026-08-02 18:00:00	3
3469	39	39	SALE	6	2026-08-03 20:36:00	3
3470	39	39	SALE	7	2026-08-04 09:19:00	3
3471	39	39	SALE	8	2026-08-05 15:12:00	3
3472	39	39	SALE	7	2026-08-06 16:24:00	3
3473	39	39	SALE	6	2026-08-07 15:02:00	3
3474	39	39	SALE	12	2026-08-08 20:43:00	3
3475	39	39	SALE	11	2026-08-09 13:44:00	3
3476	39	39	SALE	7	2026-08-10 15:21:00	3
3477	39	39	SALE	9	2026-08-11 14:51:00	3
3478	39	39	SALE	6	2026-08-12 17:54:00	3
3479	39	39	SALE	5	2026-08-13 15:26:00	3
3480	39	39	SALE	4	2026-08-14 20:21:00	3
3481	39	39	SALE	11	2026-08-15 11:22:00	3
3482	39	39	SALE	9	2026-08-16 20:16:00	3
3483	39	39	SALE	6	2026-08-17 17:12:00	3
3484	39	39	SALE	8	2026-08-18 16:18:00	3
3485	39	39	SALE	6	2026-08-19 13:05:00	3
3486	39	39	SALE	8	2026-08-20 16:58:00	3
3487	39	39	SALE	8	2026-08-21 19:05:00	3
3488	39	39	SALE	7	2026-08-22 19:58:00	3
3489	39	39	SALE	12	2026-08-23 14:55:00	3
3490	39	39	SALE	5	2026-08-24 17:57:00	3
3491	39	39	SALE	8	2026-08-25 10:01:00	3
3492	39	39	SALE	6	2026-08-26 11:51:00	3
3493	39	39	SALE	8	2026-08-27 10:15:00	3
3494	39	39	SALE	7	2026-08-28 10:11:00	3
3495	39	39	SALE	10	2026-08-29 14:04:00	3
3496	39	39	SALE	8	2026-08-30 11:36:00	3
3497	39	39	SALE	5	2026-08-31 12:49:00	3
3498	39	39	SALE	5	2026-09-01 10:55:00	3
3499	39	39	SALE	8	2026-09-02 10:00:00	3
3500	39	39	SALE	9	2026-09-03 20:00:00	3
3501	39	39	SALE	8	2026-09-04 20:51:00	3
3502	39	39	SALE	10	2026-09-05 14:55:00	3
3503	39	39	SALE	10	2026-09-06 18:04:00	3
3504	39	39	SALE	6	2026-09-07 11:37:00	3
3505	39	39	SALE	8	2026-09-08 19:55:00	3
3506	39	39	SALE	7	2026-09-09 16:40:00	3
3507	39	39	SALE	6	2026-09-10 14:50:00	3
3508	39	39	SALE	7	2026-09-11 19:06:00	3
3509	39	39	SALE	8	2026-09-12 18:07:00	3
3510	39	39	SALE	8	2026-09-13 09:45:00	3
3511	39	39	SALE	8	2026-09-14 11:12:00	3
3512	39	39	SALE	8	2026-09-15 20:59:00	3
3513	39	39	SALE	6	2026-09-16 10:11:00	3
3514	39	39	SALE	7	2026-09-17 10:45:00	3
3515	39	39	SALE	4	2026-09-18 10:00:00	3
3516	39	39	SALE	12	2026-09-19 15:50:00	3
3517	39	39	SALE	10	2026-09-20 19:14:00	3
3518	39	39	SALE	8	2026-09-21 12:03:00	3
3519	39	39	SALE	6	2026-09-22 20:05:00	3
3520	39	39	SALE	8	2026-09-23 15:20:00	3
3521	39	39	SALE	6	2026-09-24 19:33:00	3
3522	39	39	SALE	8	2026-09-25 12:30:00	3
3523	39	39	SALE	8	2026-09-26 12:45:00	3
3524	39	39	SALE	11	2026-09-27 16:38:00	3
3525	39	39	SALE	7	2026-09-28 20:11:00	3
3526	39	39	SALE	6	2026-09-29 16:18:00	3
3527	39	39	SALE	6	2026-09-30 20:43:00	3
3528	39	39	SALE	9	2026-10-01 18:55:00	3
3529	39	39	SALE	7	2026-10-02 09:28:00	3
3530	39	39	SALE	11	2026-10-03 11:32:00	3
3531	39	39	SALE	10	2026-10-04 09:05:00	3
3532	39	39	SALE	16	2026-10-05 11:12:00	3
3533	39	39	SALE	8	2026-10-06 13:09:00	3
3534	39	39	SALE	9	2026-10-07 17:36:00	3
3535	39	39	SALE	6	2026-10-08 12:44:00	3
3536	39	39	SALE	10	2026-10-09 10:44:00	3
3537	39	39	SALE	10	2026-10-10 10:12:00	3
3538	39	39	SALE	11	2026-10-11 11:54:00	3
3539	39	39	SALE	7	2026-10-12 14:48:00	3
3540	39	39	SALE	10	2026-10-13 12:10:00	3
3541	39	39	SALE	11	2026-10-14 15:40:00	3
3542	39	39	SALE	8	2026-10-15 18:18:00	3
3543	39	39	SALE	7	2026-10-16 18:26:00	3
3544	39	39	SALE	20	2026-10-17 17:40:00	3
3545	39	39	SALE	8	2026-10-18 13:13:00	3
3546	39	39	SALE	8	2026-10-19 15:16:00	3
3547	39	39	SALE	6	2026-10-20 14:47:00	3
3548	39	39	SALE	8	2026-10-21 12:33:00	3
3549	39	39	SALE	6	2026-10-22 09:41:00	3
3550	40	40	RECEIPT	685	2026-07-25 08:00:00	2
3551	40	40	SALE	8	2026-07-25 10:33:00	3
3552	40	40	SALE	7	2026-07-26 11:45:00	3
3553	40	40	SALE	6	2026-07-27 12:05:00	3
3554	40	40	SALE	6	2026-07-28 14:22:00	3
3555	40	40	SALE	5	2026-07-29 14:05:00	3
3556	40	40	SALE	4	2026-07-30 15:21:00	3
3557	40	40	SALE	6	2026-07-31 10:31:00	3
3558	40	40	SALE	8	2026-08-01 15:34:00	3
3559	40	40	SALE	10	2026-08-02 09:33:00	3
3560	40	40	SALE	6	2026-08-03 15:41:00	3
3561	40	40	SALE	5	2026-08-04 15:44:00	3
3562	40	40	SALE	8	2026-08-05 11:35:00	3
3563	40	40	SALE	4	2026-08-06 10:52:00	3
3564	40	40	SALE	6	2026-08-07 12:28:00	3
3565	40	40	SALE	8	2026-08-08 11:07:00	3
3566	40	40	SALE	7	2026-08-09 13:14:00	3
3567	40	40	SALE	7	2026-08-10 12:03:00	3
3568	40	40	SALE	6	2026-08-11 19:43:00	3
3569	40	40	SALE	7	2026-08-12 17:01:00	3
3570	40	40	SALE	8	2026-08-13 09:41:00	3
3571	40	40	SALE	7	2026-08-14 20:14:00	3
3572	40	40	SALE	7	2026-08-15 16:02:00	3
3573	40	40	SALE	6	2026-08-16 09:14:00	3
3574	40	40	SALE	7	2026-08-17 12:09:00	3
3575	40	40	SALE	17	2026-08-18 11:32:00	3
3576	40	40	SALE	6	2026-08-19 14:20:00	3
3577	40	40	SALE	6	2026-08-20 15:48:00	3
3578	40	40	SALE	7	2026-08-21 19:42:00	3
3579	40	40	SALE	9	2026-08-22 15:01:00	3
3580	40	40	SALE	9	2026-08-23 17:48:00	3
3581	40	40	SALE	7	2026-08-24 13:31:00	3
3582	40	40	SALE	5	2026-08-25 09:42:00	3
3583	40	40	SALE	8	2026-08-26 20:44:00	3
3584	40	40	SALE	8	2026-08-27 15:35:00	3
3585	40	40	SALE	7	2026-08-28 10:02:00	3
3586	40	40	SALE	9	2026-08-29 12:37:00	3
3587	40	40	SALE	8	2026-08-30 09:13:00	3
3588	40	40	SALE	5	2026-08-31 12:37:00	3
3589	40	40	SALE	5	2026-09-01 16:00:00	3
3590	40	40	SALE	5	2026-09-02 14:44:00	3
3591	40	40	SALE	5	2026-09-03 10:37:00	3
3592	40	40	SALE	7	2026-09-04 14:32:00	3
3593	40	40	SALE	10	2026-09-05 11:25:00	3
3594	40	40	SALE	9	2026-09-06 12:09:00	3
3595	40	40	SALE	8	2026-09-07 17:00:00	3
3596	40	40	SALE	5	2026-09-08 19:47:00	3
3597	40	40	SALE	5	2026-09-09 18:18:00	3
3598	40	40	SALE	6	2026-09-10 13:35:00	3
3599	40	40	SALE	5	2026-09-11 14:32:00	3
3600	40	40	SALE	6	2026-09-12 15:10:00	3
3601	40	40	SALE	8	2026-09-13 12:48:00	3
3602	40	40	SALE	4	2026-09-14 18:16:00	3
3603	40	40	SALE	4	2026-09-15 14:12:00	3
3604	40	40	SALE	5	2026-09-16 14:57:00	3
3605	40	40	SALE	5	2026-09-17 13:25:00	3
3606	40	40	SALE	6	2026-09-18 10:41:00	3
3607	40	40	SALE	11	2026-09-19 13:28:00	3
3608	40	40	SALE	6	2026-09-20 09:28:00	3
3609	40	40	SALE	7	2026-09-21 18:41:00	3
3610	40	40	SALE	8	2026-09-22 19:32:00	3
3611	40	40	SALE	6	2026-09-23 15:13:00	3
3612	40	40	SALE	12	2026-09-24 11:07:00	3
3613	40	40	SALE	5	2026-09-25 09:24:00	3
3614	40	40	SALE	8	2026-09-26 10:47:00	3
3615	40	40	SALE	9	2026-09-27 12:12:00	3
3616	40	40	SALE	5	2026-09-28 18:47:00	3
3617	40	40	SALE	7	2026-09-29 20:19:00	3
3618	40	40	SALE	5	2026-09-30 20:43:00	3
3619	40	40	SALE	7	2026-10-01 12:56:00	3
3620	40	40	SALE	5	2026-10-02 18:52:00	3
3621	40	40	SALE	8	2026-10-03 13:23:00	3
3622	40	40	SALE	6	2026-10-04 16:03:00	3
3623	40	40	SALE	8	2026-10-05 19:40:00	3
3624	40	40	SALE	6	2026-10-06 12:36:00	3
3625	40	40	SALE	7	2026-10-07 13:13:00	3
3626	40	40	SALE	2	2026-10-08 17:01:00	3
3627	40	40	SALE	7	2026-10-09 13:00:00	3
3628	40	40	SALE	10	2026-10-10 12:53:00	3
3629	40	40	SALE	7	2026-10-11 11:55:00	3
3630	40	40	SALE	5	2026-10-12 14:13:00	3
3631	40	40	SALE	6	2026-10-13 16:46:00	3
3632	40	40	SALE	6	2026-10-14 15:46:00	3
3633	40	40	SALE	7	2026-10-15 14:29:00	3
3634	40	40	SALE	8	2026-10-16 15:38:00	3
3635	40	40	SALE	8	2026-10-17 11:58:00	3
3636	40	40	SALE	9	2026-10-18 16:30:00	3
3637	40	40	SALE	5	2026-10-19 17:38:00	3
3638	40	40	SALE	8	2026-10-20 13:50:00	3
3639	40	40	SALE	6	2026-10-21 19:54:00	3
3640	40	40	SALE	4	2026-10-22 12:04:00	3
3641	41	41	RECEIPT	2689	2026-07-25 08:00:00	2
3642	41	41	SALE	38	2026-07-25 20:54:00	3
3643	41	41	SALE	27	2026-07-26 16:13:00	3
3644	41	41	SALE	25	2026-07-27 18:26:00	3
3645	41	41	SALE	20	2026-07-28 10:00:00	3
3646	41	41	SALE	23	2026-07-29 19:08:00	3
3647	41	41	SALE	23	2026-07-30 18:55:00	3
3648	41	41	SALE	14	2026-07-31 19:49:00	3
3649	41	41	SALE	35	2026-08-01 09:59:00	3
3650	41	41	SALE	35	2026-08-02 17:28:00	3
3651	41	41	SALE	20	2026-08-03 10:32:00	3
3652	41	41	SALE	28	2026-08-04 11:29:00	3
3653	41	41	SALE	17	2026-08-05 13:44:00	3
3654	41	41	SALE	22	2026-08-06 18:24:00	3
3655	41	41	SALE	15	2026-08-07 17:41:00	3
3656	41	41	SALE	33	2026-08-08 20:03:00	3
3657	41	41	SALE	33	2026-08-09 13:37:00	3
3658	41	41	SALE	19	2026-08-10 10:44:00	3
3659	41	41	SALE	21	2026-08-11 17:31:00	3
3660	41	41	SALE	22	2026-08-12 11:57:00	3
3661	41	41	SALE	19	2026-08-13 16:18:00	3
3662	41	41	SALE	27	2026-08-14 11:02:00	3
3663	41	41	SALE	31	2026-08-15 13:38:00	3
3664	41	41	SALE	33	2026-08-16 14:27:00	3
3665	41	41	SALE	22	2026-08-17 10:43:00	3
3666	41	41	SALE	21	2026-08-18 11:53:00	3
3667	41	41	SALE	27	2026-08-19 10:12:00	3
3668	41	41	SALE	21	2026-08-20 16:31:00	3
3669	41	41	SALE	31	2026-08-21 12:00:00	3
3670	41	41	SALE	23	2026-08-22 15:49:00	3
3671	41	41	SALE	23	2026-08-23 20:51:00	3
3672	41	41	SALE	19	2026-08-24 19:57:00	3
3673	41	41	SALE	22	2026-08-25 11:49:00	3
3674	41	41	SALE	18	2026-08-26 15:02:00	3
3675	41	41	SALE	26	2026-08-27 13:11:00	3
3676	41	41	SALE	25	2026-08-28 12:21:00	3
3677	41	41	SALE	37	2026-08-29 19:37:00	3
3678	41	41	SALE	30	2026-08-30 16:14:00	3
3679	41	41	SALE	24	2026-08-31 20:28:00	3
3680	41	41	SALE	20	2026-09-01 20:58:00	3
3681	41	41	SALE	25	2026-09-02 10:06:00	3
3682	41	41	SALE	17	2026-09-03 11:08:00	3
3683	41	41	SALE	22	2026-09-04 11:47:00	3
3684	41	41	SALE	34	2026-09-05 18:36:00	3
3685	41	41	SALE	28	2026-09-06 09:28:00	3
3686	41	41	SALE	24	2026-09-07 16:23:00	3
3687	41	41	SALE	20	2026-09-08 20:27:00	3
3688	41	41	SALE	26	2026-09-09 09:45:00	3
3689	41	41	SALE	17	2026-09-10 17:57:00	3
3690	41	41	SALE	23	2026-09-11 20:23:00	3
3691	41	41	SALE	27	2026-09-12 19:34:00	3
3692	41	41	SALE	29	2026-09-13 10:26:00	3
3693	41	41	SALE	20	2026-09-14 16:02:00	3
3694	41	41	SALE	21	2026-09-15 13:27:00	3
3695	41	41	SALE	65	2026-09-16 17:44:00	3
3696	41	41	SALE	21	2026-09-17 15:04:00	3
3697	41	41	SALE	20	2026-09-18 10:05:00	3
3698	41	41	SALE	35	2026-09-19 13:56:00	3
3699	41	41	SALE	36	2026-09-20 19:22:00	3
3700	41	41	SALE	20	2026-09-21 16:25:00	3
3701	41	41	SALE	18	2026-09-22 17:58:00	3
3702	41	41	SALE	17	2026-09-23 12:58:00	3
3703	41	41	SALE	10	2026-09-24 11:07:00	3
3704	41	41	SALE	26	2026-09-25 09:10:00	3
3705	41	41	SALE	37	2026-09-26 10:36:00	3
3706	41	41	SALE	34	2026-09-27 11:42:00	3
3707	41	41	SALE	17	2026-09-28 12:28:00	3
3708	41	41	SALE	19	2026-09-29 19:34:00	3
3709	41	41	SALE	29	2026-09-30 14:35:00	3
3710	41	41	SALE	15	2026-10-01 13:30:00	3
3711	41	41	SALE	32	2026-10-02 10:50:00	3
3712	41	41	SALE	33	2026-10-03 19:11:00	3
3713	41	41	SALE	25	2026-10-04 18:26:00	3
3714	41	41	SALE	73	2026-10-05 10:35:00	3
3715	41	41	SALE	20	2026-10-06 09:14:00	3
3716	41	41	SALE	19	2026-10-07 12:09:00	3
3717	41	41	SALE	25	2026-10-08 13:08:00	3
3718	41	41	SALE	18	2026-10-09 20:44:00	3
3719	41	41	SALE	28	2026-10-10 15:00:00	3
3720	41	41	SALE	30	2026-10-11 14:03:00	3
3721	41	41	SALE	27	2026-10-12 17:50:00	3
3722	41	41	SALE	23	2026-10-13 09:07:00	3
3723	41	41	SALE	17	2026-10-14 17:42:00	3
3724	41	41	SALE	28	2026-10-15 13:37:00	3
3725	41	41	SALE	20	2026-10-16 17:00:00	3
3726	41	41	SALE	33	2026-10-17 13:56:00	3
3727	41	41	SALE	27	2026-10-18 11:20:00	3
3728	41	41	SALE	25	2026-10-19 12:55:00	3
3729	41	41	SALE	17	2026-10-20 16:51:00	3
3730	41	41	SALE	19	2026-10-21 12:12:00	3
3731	41	41	SALE	27	2026-10-22 19:30:00	3
3732	42	42	RECEIPT	543	2026-07-25 08:00:00	2
3733	42	42	SALE	7	2026-07-25 17:39:00	3
3734	42	42	SALE	8	2026-07-26 15:53:00	3
3735	42	42	SALE	6	2026-07-27 16:38:00	3
3736	42	42	SALE	6	2026-07-28 12:23:00	3
3737	42	42	SALE	5	2026-07-29 11:45:00	3
3738	42	42	SALE	4	2026-07-30 10:38:00	3
3739	42	42	SALE	6	2026-07-31 20:43:00	3
3740	42	42	SALE	8	2026-08-01 15:10:00	3
3741	42	42	SALE	6	2026-08-02 15:13:00	3
3742	42	42	SALE	6	2026-08-03 12:20:00	3
3743	42	42	SALE	4	2026-08-04 14:25:00	3
3744	42	42	SALE	5	2026-08-05 13:15:00	3
3745	42	42	SALE	3	2026-08-06 20:18:00	3
3746	42	42	SALE	6	2026-08-07 12:24:00	3
3747	42	42	SALE	8	2026-08-08 18:56:00	3
3748	42	42	SALE	7	2026-08-09 16:01:00	3
3749	42	42	SALE	5	2026-08-10 19:59:00	3
3750	42	42	SALE	6	2026-08-11 18:15:00	3
3751	42	42	SALE	4	2026-08-12 19:44:00	3
3752	42	42	SALE	4	2026-08-13 10:28:00	3
3753	42	42	SALE	5	2026-08-14 20:51:00	3
3754	42	42	SALE	5	2026-08-15 09:24:00	3
3755	42	42	SALE	8	2026-08-16 18:22:00	3
3756	42	42	SALE	5	2026-08-17 14:24:00	3
3757	42	42	SALE	7	2026-08-18 09:31:00	3
3758	42	42	SALE	4	2026-08-19 15:46:00	3
3759	42	42	SALE	5	2026-08-20 16:58:00	3
3760	42	42	SALE	3	2026-08-21 15:05:00	3
3761	42	42	SALE	6	2026-08-22 15:16:00	3
3762	42	42	SALE	6	2026-08-23 14:14:00	3
3763	42	42	SALE	6	2026-08-24 13:23:00	3
3764	42	42	SALE	5	2026-08-25 13:30:00	3
3765	42	42	SALE	3	2026-08-26 11:10:00	3
3766	42	42	SALE	3	2026-08-27 12:54:00	3
3767	42	42	SALE	5	2026-08-28 18:41:00	3
3768	42	42	SALE	9	2026-08-29 17:38:00	3
3769	42	42	SALE	8	2026-08-30 17:51:00	3
3770	42	42	SALE	6	2026-08-31 12:54:00	3
3771	42	42	SALE	4	2026-09-01 09:24:00	3
3772	42	42	SALE	4	2026-09-02 14:03:00	3
3773	42	42	SALE	5	2026-09-03 12:05:00	3
3774	42	42	SALE	3	2026-09-04 20:58:00	3
3775	42	42	SALE	7	2026-09-05 11:05:00	3
3776	42	42	SALE	6	2026-09-06 18:44:00	3
3777	42	42	SALE	6	2026-09-07 17:03:00	3
3778	42	42	SALE	6	2026-09-08 13:05:00	3
3779	42	42	SALE	4	2026-09-09 17:59:00	3
3780	42	42	SALE	4	2026-09-10 13:28:00	3
3781	42	42	SALE	5	2026-09-11 11:18:00	3
3782	42	42	SALE	6	2026-09-12 11:54:00	3
3783	42	42	SALE	7	2026-09-13 15:17:00	3
3784	42	42	SALE	6	2026-09-14 11:14:00	3
3785	42	42	SALE	4	2026-09-15 15:19:00	3
3786	42	42	SALE	6	2026-09-16 11:33:00	3
3787	42	42	SALE	5	2026-09-17 10:14:00	3
3788	42	42	SALE	4	2026-09-18 10:39:00	3
3789	42	42	SALE	8	2026-09-19 09:36:00	3
3790	42	42	SALE	6	2026-09-20 19:50:00	3
3791	42	42	SALE	4	2026-09-21 20:11:00	3
3792	42	42	SALE	4	2026-09-22 13:35:00	3
3793	42	42	SALE	5	2026-09-23 16:27:00	3
3794	42	42	SALE	6	2026-09-24 11:15:00	3
3795	42	42	SALE	5	2026-09-25 09:51:00	3
3796	42	42	SALE	7	2026-09-26 12:38:00	3
3797	42	42	SALE	8	2026-09-27 20:04:00	3
3798	42	42	SALE	6	2026-09-28 10:49:00	3
3799	42	42	SALE	5	2026-09-29 10:17:00	3
3800	42	42	SALE	5	2026-09-30 11:34:00	3
3801	42	42	SALE	5	2026-10-01 10:49:00	3
3802	42	42	SALE	4	2026-10-02 16:35:00	3
3803	42	42	SALE	7	2026-10-03 14:46:00	3
3804	42	42	SALE	4	2026-10-04 11:09:00	3
3805	42	42	SALE	4	2026-10-05 17:59:00	3
3806	42	42	SALE	4	2026-10-06 11:15:00	3
3807	42	42	SALE	9	2026-10-07 09:20:00	3
3808	42	42	SALE	6	2026-10-08 11:49:00	3
3809	42	42	SALE	3	2026-10-09 13:32:00	3
3810	42	42	SALE	5	2026-10-10 09:32:00	3
3811	42	42	SALE	7	2026-10-11 17:57:00	3
3812	42	42	SALE	6	2026-10-12 09:25:00	3
3813	42	42	SALE	5	2026-10-13 11:10:00	3
3814	42	42	SALE	5	2026-10-14 09:30:00	3
3815	42	42	SALE	6	2026-10-15 11:54:00	3
3816	42	42	SALE	4	2026-10-16 11:15:00	3
3817	42	42	SALE	6	2026-10-17 18:53:00	3
3818	42	42	SALE	8	2026-10-18 14:36:00	3
3819	42	42	SALE	5	2026-10-19 13:29:00	3
3820	42	42	SALE	5	2026-10-20 12:29:00	3
3821	42	42	SALE	5	2026-10-21 11:45:00	3
3822	42	42	SALE	4	2026-10-22 10:45:00	3
3823	43	43	RECEIPT	753	2026-07-25 08:00:00	2
3824	43	43	SALE	7	2026-07-25 10:59:00	3
3825	43	43	SALE	17	2026-07-26 20:41:00	3
3826	43	43	SALE	7	2026-07-27 11:03:00	3
3827	43	43	SALE	4	2026-07-28 09:30:00	3
3828	43	43	SALE	5	2026-07-29 11:02:00	3
3829	43	43	SALE	7	2026-07-30 11:18:00	3
3830	43	43	SALE	5	2026-07-31 14:43:00	3
3831	43	43	SALE	10	2026-08-01 19:58:00	3
3832	43	43	SALE	7	2026-08-02 20:22:00	3
3833	43	43	SALE	7	2026-08-03 19:36:00	3
3834	43	43	SALE	6	2026-08-04 10:02:00	3
3835	43	43	SALE	8	2026-08-05 11:57:00	3
3836	43	43	SALE	5	2026-08-06 13:21:00	3
3837	43	43	SALE	5	2026-08-07 10:02:00	3
3838	43	43	SALE	8	2026-08-08 18:05:00	3
3839	43	43	SALE	9	2026-08-09 09:39:00	3
3840	43	43	SALE	7	2026-08-10 09:52:00	3
3841	43	43	SALE	4	2026-08-11 12:50:00	3
3842	43	43	SALE	13	2026-08-12 11:57:00	3
3843	43	43	SALE	7	2026-08-13 15:52:00	3
3844	43	43	SALE	5	2026-08-14 16:06:00	3
3845	43	43	SALE	9	2026-08-15 13:37:00	3
3846	43	43	SALE	11	2026-08-16 13:39:00	3
3847	43	43	SALE	7	2026-08-17 17:04:00	3
3848	43	43	SALE	6	2026-08-18 18:18:00	3
3849	43	43	SALE	6	2026-08-19 11:04:00	3
3850	43	43	SALE	5	2026-08-20 16:38:00	3
3851	43	43	SALE	5	2026-08-21 13:10:00	3
3852	43	43	SALE	6	2026-08-22 19:49:00	3
3853	43	43	SALE	9	2026-08-23 20:32:00	3
3854	43	43	SALE	7	2026-08-24 10:31:00	3
3855	43	43	SALE	9	2026-08-25 18:14:00	3
3856	43	43	SALE	7	2026-08-26 20:18:00	3
3857	43	43	SALE	8	2026-08-27 09:25:00	3
3858	43	43	SALE	6	2026-08-28 14:42:00	3
3859	43	43	SALE	10	2026-08-29 11:44:00	3
3860	43	43	SALE	8	2026-08-30 16:51:00	3
3861	43	43	SALE	5	2026-08-31 16:22:00	3
3862	43	43	SALE	7	2026-09-01 17:19:00	3
3863	43	43	SALE	7	2026-09-02 13:41:00	3
3864	43	43	SALE	8	2026-09-03 20:52:00	3
3865	43	43	SALE	6	2026-09-04 15:26:00	3
3866	43	43	SALE	11	2026-09-05 12:50:00	3
3867	43	43	SALE	8	2026-09-06 13:42:00	3
3868	43	43	SALE	6	2026-09-07 14:13:00	3
3869	43	43	SALE	5	2026-09-08 12:29:00	3
3870	43	43	SALE	7	2026-09-09 11:45:00	3
3871	43	43	SALE	7	2026-09-10 11:02:00	3
3872	43	43	SALE	5	2026-09-11 10:03:00	3
3873	43	43	SALE	11	2026-09-12 18:56:00	3
3874	43	43	SALE	10	2026-09-13 10:09:00	3
3875	43	43	SALE	7	2026-09-14 10:28:00	3
3876	43	43	SALE	6	2026-09-15 11:09:00	3
3877	43	43	SALE	6	2026-09-16 20:04:00	3
3878	43	43	SALE	6	2026-09-17 13:49:00	3
3879	43	43	SALE	6	2026-09-18 14:44:00	3
3880	43	43	SALE	8	2026-09-19 14:37:00	3
3881	43	43	SALE	9	2026-09-20 12:45:00	3
3882	43	43	SALE	8	2026-09-21 16:27:00	3
3883	43	43	SALE	6	2026-09-22 15:07:00	3
3884	43	43	SALE	4	2026-09-23 19:42:00	3
3885	43	43	SALE	5	2026-09-24 19:35:00	3
3886	43	43	SALE	5	2026-09-25 20:37:00	3
3887	43	43	SALE	8	2026-09-26 13:59:00	3
3888	43	43	SALE	9	2026-09-27 20:13:00	3
3889	43	43	SALE	4	2026-09-28 16:41:00	3
3890	43	43	SALE	5	2026-09-29 09:23:00	3
3891	43	43	SALE	6	2026-09-30 11:25:00	3
3892	43	43	SALE	10	2026-10-01 12:22:00	3
3893	43	43	SALE	5	2026-10-02 10:03:00	3
3894	43	43	SALE	9	2026-10-03 09:53:00	3
3895	43	43	SALE	11	2026-10-04 13:24:00	3
3896	43	43	SALE	7	2026-10-05 11:52:00	3
3897	43	43	SALE	6	2026-10-06 16:29:00	3
3898	43	43	SALE	5	2026-10-07 19:25:00	3
3899	43	43	SALE	6	2026-10-08 20:55:00	3
3900	43	43	SALE	6	2026-10-09 14:28:00	3
3901	43	43	SALE	9	2026-10-10 11:52:00	3
3902	43	43	SALE	7	2026-10-11 14:47:00	3
3903	43	43	SALE	8	2026-10-12 20:27:00	3
3904	43	43	SALE	7	2026-10-13 19:20:00	3
3905	43	43	SALE	7	2026-10-14 18:55:00	3
3906	43	43	SALE	7	2026-10-15 20:11:00	3
3907	43	43	SALE	7	2026-10-16 09:55:00	3
3908	43	43	SALE	8	2026-10-17 11:16:00	3
3909	43	43	SALE	7	2026-10-18 15:05:00	3
3910	43	43	SALE	6	2026-10-19 16:56:00	3
3911	43	43	SALE	7	2026-10-20 14:09:00	3
3912	43	43	SALE	6	2026-10-21 09:56:00	3
3913	43	43	SALE	15	2026-10-22 11:15:00	3
3914	44	44	RECEIPT	1447	2026-07-25 08:00:00	2
3915	44	44	SALE	15	2026-07-25 17:38:00	3
3916	44	44	SALE	16	2026-07-26 18:54:00	3
3917	44	44	SALE	14	2026-07-27 10:23:00	3
3918	44	44	SALE	12	2026-07-28 10:06:00	3
3919	44	44	SALE	11	2026-07-29 13:49:00	3
3920	44	44	SALE	13	2026-07-30 14:20:00	3
3921	44	44	SALE	12	2026-07-31 10:11:00	3
3922	44	44	SALE	19	2026-08-01 18:13:00	3
3923	44	44	SALE	14	2026-08-02 18:51:00	3
3924	44	44	SALE	14	2026-08-03 10:14:00	3
3925	44	44	SALE	13	2026-08-04 09:17:00	3
3926	44	44	SALE	16	2026-08-05 13:53:00	3
3927	44	44	SALE	15	2026-08-06 17:48:00	3
3928	44	44	SALE	11	2026-08-07 17:58:00	3
3929	44	44	SALE	17	2026-08-08 10:51:00	3
3930	44	44	SALE	18	2026-08-09 20:35:00	3
3931	44	44	SALE	13	2026-08-10 18:55:00	3
3932	44	44	SALE	10	2026-08-11 20:34:00	3
3933	44	44	SALE	7	2026-08-12 13:58:00	3
3934	44	44	SALE	10	2026-08-13 17:42:00	3
3935	44	44	SALE	12	2026-08-14 13:06:00	3
3936	44	44	SALE	23	2026-08-15 15:48:00	3
3937	44	44	SALE	17	2026-08-16 09:19:00	3
3938	44	44	SALE	12	2026-08-17 15:05:00	3
3939	44	44	SALE	27	2026-08-18 19:21:00	3
3940	44	44	SALE	10	2026-08-19 13:47:00	3
3941	44	44	SALE	13	2026-08-20 09:08:00	3
3942	44	44	SALE	9	2026-08-21 10:06:00	3
3943	44	44	SALE	18	2026-08-22 18:00:00	3
3944	44	44	SALE	15	2026-08-23 10:57:00	3
3945	44	44	SALE	11	2026-08-24 16:02:00	3
3946	44	44	SALE	10	2026-08-25 16:51:00	3
3947	44	44	SALE	8	2026-08-26 14:25:00	3
3948	44	44	SALE	11	2026-08-27 17:06:00	3
3949	44	44	SALE	9	2026-08-28 13:10:00	3
3950	44	44	SALE	49	2026-08-29 18:35:00	3
3951	44	44	SALE	16	2026-08-30 12:05:00	3
3952	44	44	SALE	15	2026-08-31 14:10:00	3
3953	44	44	SALE	12	2026-09-01 11:41:00	3
3954	44	44	SALE	11	2026-09-02 18:44:00	3
3955	44	44	SALE	13	2026-09-03 10:40:00	3
3956	44	44	SALE	14	2026-09-04 09:30:00	3
3957	44	44	SALE	15	2026-09-05 12:46:00	3
3958	44	44	SALE	25	2026-09-06 20:08:00	3
3959	44	44	SALE	13	2026-09-07 11:47:00	3
3960	44	44	SALE	13	2026-09-08 19:32:00	3
3961	44	44	SALE	16	2026-09-09 12:26:00	3
3962	44	44	SALE	14	2026-09-10 09:43:00	3
3963	44	44	SALE	14	2026-09-11 17:56:00	3
3964	44	44	SALE	20	2026-09-12 13:36:00	3
3965	44	44	SALE	14	2026-09-13 20:49:00	3
3966	44	44	SALE	12	2026-09-14 12:31:00	3
3967	44	44	SALE	11	2026-09-15 17:15:00	3
3968	44	44	SALE	13	2026-09-16 09:27:00	3
3969	44	44	SALE	29	2026-09-17 12:39:00	3
3970	44	44	SALE	11	2026-09-18 19:24:00	3
3971	44	44	SALE	18	2026-09-19 12:52:00	3
3972	44	44	SALE	16	2026-09-20 17:18:00	3
3973	44	44	SALE	9	2026-09-21 14:08:00	3
3974	44	44	SALE	11	2026-09-22 15:37:00	3
3975	44	44	SALE	17	2026-09-23 15:58:00	3
3976	44	44	SALE	13	2026-09-24 18:18:00	3
3977	44	44	SALE	13	2026-09-25 13:15:00	3
3978	44	44	SALE	12	2026-09-26 18:54:00	3
3979	44	44	SALE	14	2026-09-27 10:45:00	3
3980	44	44	SALE	10	2026-09-28 15:16:00	3
3981	44	44	SALE	15	2026-09-29 19:38:00	3
3982	44	44	SALE	7	2026-09-30 16:00:00	3
3983	44	44	SALE	10	2026-10-01 10:25:00	3
3984	44	44	SALE	13	2026-10-02 18:12:00	3
3985	44	44	SALE	45	2026-10-03 20:16:00	3
3986	44	44	SALE	19	2026-10-04 20:08:00	3
3987	44	44	SALE	12	2026-10-05 18:11:00	3
3988	44	44	SALE	12	2026-10-06 19:37:00	3
3989	44	44	SALE	13	2026-10-07 10:42:00	3
3990	44	44	SALE	13	2026-10-08 12:08:00	3
3991	44	44	SALE	10	2026-10-09 20:02:00	3
3992	44	44	SALE	15	2026-10-10 12:15:00	3
3993	44	44	SALE	17	2026-10-11 20:02:00	3
3994	44	44	SALE	8	2026-10-12 20:04:00	3
3995	44	44	SALE	10	2026-10-13 19:25:00	3
3996	44	44	SALE	11	2026-10-14 11:13:00	3
3997	44	44	SALE	15	2026-10-15 13:07:00	3
3998	44	44	SALE	11	2026-10-16 18:00:00	3
3999	44	44	SALE	20	2026-10-17 19:13:00	3
4000	44	44	SALE	18	2026-10-18 20:07:00	3
4001	44	44	SALE	10	2026-10-19 20:00:00	3
4002	44	44	SALE	14	2026-10-20 15:06:00	3
4003	44	44	SALE	14	2026-10-21 14:13:00	3
4004	44	44	SALE	12	2026-10-22 16:09:00	3
4005	45	45	RECEIPT	2423	2026-07-25 08:00:00	2
4006	45	45	SALE	28	2026-07-25 15:11:00	3
4007	45	45	SALE	31	2026-07-26 18:53:00	3
4008	45	45	SALE	18	2026-07-27 16:17:00	3
4009	45	45	SALE	22	2026-07-28 14:16:00	3
4010	45	45	SALE	25	2026-07-29 18:13:00	3
4011	45	45	SALE	25	2026-07-30 20:51:00	3
4012	45	45	SALE	25	2026-07-31 09:12:00	3
4013	45	45	SALE	29	2026-08-01 15:18:00	3
4014	45	45	SALE	27	2026-08-02 15:49:00	3
4015	45	45	SALE	22	2026-08-03 17:29:00	3
4016	45	45	SALE	18	2026-08-04 10:55:00	3
4017	45	45	SALE	23	2026-08-05 18:07:00	3
4018	45	45	SALE	24	2026-08-06 20:08:00	3
4019	45	45	SALE	70	2026-08-07 09:14:00	3
4020	45	45	SALE	27	2026-08-08 20:44:00	3
4021	45	45	SALE	28	2026-08-09 17:54:00	3
4022	45	45	SALE	21	2026-08-10 10:35:00	3
4023	45	45	SALE	27	2026-08-11 16:25:00	3
4024	45	45	SALE	54	2026-08-12 19:37:00	3
4025	45	45	SALE	31	2026-08-13 20:47:00	3
4026	45	45	SALE	24	2026-08-14 11:03:00	3
4027	45	45	SALE	43	2026-08-15 17:11:00	3
4028	45	45	SALE	25	2026-08-16 17:56:00	3
4029	45	45	SALE	21	2026-08-17 12:51:00	3
4030	45	45	SALE	24	2026-08-18 11:15:00	3
4031	45	45	SALE	15	2026-08-19 09:32:00	3
4032	45	45	SALE	24	2026-08-20 18:34:00	3
4033	45	45	SALE	20	2026-08-21 10:15:00	3
4034	45	45	SALE	29	2026-08-22 17:35:00	3
4035	45	45	SALE	27	2026-08-23 10:21:00	3
4036	45	45	SALE	24	2026-08-24 17:34:00	3
4037	45	45	SALE	27	2026-08-25 10:16:00	3
4038	45	45	SALE	29	2026-08-26 13:21:00	3
4039	45	45	SALE	23	2026-08-27 17:08:00	3
4040	45	45	SALE	19	2026-08-28 11:02:00	3
4041	45	45	SALE	36	2026-08-29 15:31:00	3
4042	45	45	SALE	29	2026-08-30 12:08:00	3
4043	45	45	SALE	19	2026-08-31 12:44:00	3
4044	45	45	SALE	25	2026-09-01 19:05:00	3
4045	45	45	SALE	17	2026-09-02 17:09:00	3
4046	45	45	SALE	19	2026-09-03 18:28:00	3
4047	45	45	SALE	23	2026-09-04 10:27:00	3
4048	45	45	SALE	27	2026-09-05 20:40:00	3
4049	45	45	SALE	30	2026-09-06 17:05:00	3
4050	45	45	SALE	24	2026-09-07 20:48:00	3
4051	45	45	SALE	22	2026-09-08 14:29:00	3
4052	45	45	SALE	21	2026-09-09 11:43:00	3
4053	45	45	SALE	23	2026-09-10 13:54:00	3
4054	45	45	SALE	22	2026-09-11 14:01:00	3
4055	45	45	SALE	29	2026-09-12 09:48:00	3
4056	45	45	SALE	31	2026-09-13 09:49:00	3
4057	45	45	SALE	67	2026-09-14 09:49:00	3
4058	45	45	SALE	25	2026-09-15 19:44:00	3
4059	45	45	SALE	24	2026-09-16 09:55:00	3
4060	45	45	SALE	23	2026-09-17 20:01:00	3
4061	45	45	SALE	26	2026-09-18 10:20:00	3
4062	45	45	SALE	34	2026-09-19 11:48:00	3
4063	45	45	SALE	27	2026-09-20 20:51:00	3
4064	45	45	SALE	20	2026-09-21 19:37:00	3
4065	45	45	SALE	17	2026-09-22 10:05:00	3
4066	45	45	SALE	30	2026-09-23 20:12:00	3
4067	45	45	SALE	22	2026-09-24 16:51:00	3
4068	45	45	SALE	19	2026-09-25 10:28:00	3
4069	45	45	SALE	33	2026-09-26 17:41:00	3
4070	45	45	SALE	26	2026-09-27 14:03:00	3
4071	45	45	SALE	24	2026-09-28 19:47:00	3
4072	45	45	SALE	22	2026-09-29 18:01:00	3
4073	45	45	SALE	21	2026-09-30 20:09:00	3
4074	45	45	SALE	25	2026-10-01 14:20:00	3
4075	45	45	SALE	22	2026-10-02 15:43:00	3
4076	45	45	SALE	32	2026-10-03 10:50:00	3
4077	45	45	SALE	26	2026-10-04 17:41:00	3
4078	45	45	SALE	20	2026-10-05 13:48:00	3
4079	45	45	SALE	19	2026-10-06 13:16:00	3
4080	45	45	SALE	25	2026-10-07 11:05:00	3
4081	45	45	SALE	20	2026-10-08 17:52:00	3
4082	45	45	SALE	20	2026-10-09 11:38:00	3
4083	45	45	SALE	35	2026-10-10 19:36:00	3
4084	45	45	SALE	35	2026-10-11 17:30:00	3
4085	45	45	SALE	22	2026-10-12 13:31:00	3
4086	45	45	SALE	24	2026-10-13 17:58:00	3
4087	45	45	SALE	21	2026-10-14 10:09:00	3
4088	45	45	SALE	23	2026-10-15 11:52:00	3
4089	45	45	SALE	24	2026-10-16 13:32:00	3
4090	45	45	SALE	24	2026-10-17 18:50:00	3
4091	45	45	SALE	32	2026-10-18 09:20:00	3
4092	45	45	SALE	30	2026-10-19 15:30:00	3
4093	45	45	SALE	16	2026-10-20 09:32:00	3
4094	45	45	SALE	30	2026-10-21 15:29:00	3
4095	45	45	SALE	35	2026-10-22 09:02:00	3
4096	46	46	RECEIPT	1410	2026-07-25 08:00:00	2
4097	46	46	SALE	20	2026-07-25 15:12:00	3
4098	46	46	SALE	18	2026-07-26 11:52:00	3
4099	46	46	SALE	11	2026-07-27 20:10:00	3
4100	46	46	SALE	15	2026-07-28 12:38:00	3
4101	46	46	SALE	11	2026-07-29 18:32:00	3
4102	46	46	SALE	12	2026-07-30 11:04:00	3
4103	46	46	SALE	13	2026-07-31 12:28:00	3
4104	46	46	SALE	20	2026-08-01 13:21:00	3
4105	46	46	SALE	18	2026-08-02 14:26:00	3
4106	46	46	SALE	14	2026-08-03 10:05:00	3
4107	46	46	SALE	15	2026-08-04 13:59:00	3
4108	46	46	SALE	14	2026-08-05 09:44:00	3
4109	46	46	SALE	10	2026-08-06 20:54:00	3
4110	46	46	SALE	31	2026-08-07 20:18:00	3
4111	46	46	SALE	24	2026-08-08 11:33:00	3
4112	46	46	SALE	15	2026-08-09 17:26:00	3
4113	46	46	SALE	14	2026-08-10 20:02:00	3
4114	46	46	SALE	13	2026-08-11 14:40:00	3
4115	46	46	SALE	15	2026-08-12 09:49:00	3
4116	46	46	SALE	39	2026-08-13 14:15:00	3
4117	46	46	SALE	13	2026-08-14 16:59:00	3
4118	46	46	SALE	24	2026-08-15 15:27:00	3
4119	46	46	SALE	17	2026-08-16 15:50:00	3
4120	46	46	SALE	13	2026-08-17 20:02:00	3
4121	46	46	SALE	15	2026-08-18 17:44:00	3
4122	46	46	SALE	14	2026-08-19 10:07:00	3
4123	46	46	SALE	12	2026-08-20 20:08:00	3
4124	46	46	SALE	10	2026-08-21 15:49:00	3
4125	46	46	SALE	16	2026-08-22 09:02:00	3
4126	46	46	SALE	14	2026-08-23 12:55:00	3
4127	46	46	SALE	9	2026-08-24 09:33:00	3
4128	46	46	SALE	15	2026-08-25 12:23:00	3
4129	46	46	SALE	11	2026-08-26 15:25:00	3
4130	46	46	SALE	13	2026-08-27 18:05:00	3
4131	46	46	SALE	18	2026-08-28 09:24:00	3
4132	46	46	SALE	20	2026-08-29 11:43:00	3
4133	46	46	SALE	15	2026-08-30 16:04:00	3
4134	46	46	SALE	16	2026-08-31 14:47:00	3
4135	46	46	SALE	16	2026-09-01 12:06:00	3
4136	46	46	SALE	14	2026-09-02 11:49:00	3
4137	46	46	SALE	11	2026-09-03 12:16:00	3
4138	46	46	SALE	16	2026-09-04 14:22:00	3
4139	46	46	SALE	20	2026-09-05 09:52:00	3
4140	46	46	SALE	18	2026-09-06 15:32:00	3
4141	46	46	SALE	12	2026-09-07 17:11:00	3
4142	46	46	SALE	16	2026-09-08 15:36:00	3
4143	46	46	SALE	17	2026-09-09 10:31:00	3
4144	46	46	SALE	11	2026-09-10 19:54:00	3
4145	46	46	SALE	10	2026-09-11 16:27:00	3
4146	46	46	SALE	18	2026-09-12 17:41:00	3
4147	46	46	SALE	15	2026-09-13 11:39:00	3
4148	46	46	SALE	14	2026-09-14 12:33:00	3
4149	46	46	SALE	17	2026-09-15 13:18:00	3
4150	46	46	SALE	14	2026-09-16 20:02:00	3
4151	46	46	SALE	13	2026-09-17 10:15:00	3
4152	46	46	SALE	19	2026-09-18 13:57:00	3
4153	46	46	SALE	19	2026-09-19 17:00:00	3
4154	46	46	SALE	17	2026-09-20 17:28:00	3
4155	46	46	SALE	13	2026-09-21 12:21:00	3
4156	46	46	SALE	14	2026-09-22 13:15:00	3
4157	46	46	SALE	10	2026-09-23 16:55:00	3
4158	46	46	SALE	11	2026-09-24 19:58:00	3
4159	46	46	SALE	10	2026-09-25 17:47:00	3
4160	46	46	SALE	17	2026-09-26 17:08:00	3
4161	46	46	SALE	18	2026-09-27 15:02:00	3
4162	46	46	SALE	16	2026-09-28 12:14:00	3
4163	46	46	SALE	17	2026-09-29 19:23:00	3
4164	46	46	SALE	10	2026-09-30 18:46:00	3
4165	46	46	SALE	16	2026-10-01 10:03:00	3
4166	46	46	SALE	11	2026-10-02 10:42:00	3
4167	46	46	SALE	16	2026-10-03 14:28:00	3
4168	46	46	SALE	20	2026-10-04 20:44:00	3
4169	46	46	SALE	37	2026-10-05 09:38:00	3
4170	46	46	SALE	9	2026-10-06 09:32:00	3
4171	46	46	SALE	14	2026-10-07 14:36:00	3
4172	46	46	SALE	13	2026-10-08 18:45:00	3
4173	46	46	SALE	14	2026-10-09 10:51:00	3
4174	46	46	SALE	20	2026-10-10 13:18:00	3
4175	46	46	SALE	14	2026-10-11 18:11:00	3
4176	46	46	SALE	14	2026-10-12 09:45:00	3
4177	46	46	SALE	14	2026-10-13 16:16:00	3
4178	46	46	SALE	13	2026-10-14 18:51:00	3
4179	46	46	SALE	17	2026-10-15 11:25:00	3
4180	46	46	SALE	13	2026-10-16 18:45:00	3
4181	46	46	SALE	20	2026-10-17 18:39:00	3
4182	46	46	SALE	18	2026-10-18 19:26:00	3
4183	46	46	SALE	9	2026-10-19 18:36:00	3
4184	46	46	SALE	12	2026-10-20 15:55:00	3
4185	46	46	SALE	13	2026-10-21 19:18:00	3
4186	46	46	SALE	16	2026-10-22 17:41:00	3
4187	47	47	RECEIPT	767	2026-07-25 08:00:00	2
4188	47	47	SALE	7	2026-07-25 18:20:00	3
4189	47	47	SALE	8	2026-07-26 09:09:00	3
4190	47	47	SALE	7	2026-07-27 15:18:00	3
4191	47	47	SALE	5	2026-07-28 17:02:00	3
4192	47	47	SALE	4	2026-07-29 10:27:00	3
4193	47	47	SALE	8	2026-07-30 13:18:00	3
4194	47	47	SALE	6	2026-07-31 09:15:00	3
4195	47	47	SALE	8	2026-08-01 16:13:00	3
4196	47	47	SALE	9	2026-08-02 19:16:00	3
4197	47	47	SALE	7	2026-08-03 10:25:00	3
4198	47	47	SALE	6	2026-08-04 16:34:00	3
4199	47	47	SALE	4	2026-08-05 10:59:00	3
4200	47	47	SALE	7	2026-08-06 11:57:00	3
4201	47	47	SALE	6	2026-08-07 16:47:00	3
4202	47	47	SALE	7	2026-08-08 16:42:00	3
4203	47	47	SALE	5	2026-08-09 17:10:00	3
4204	47	47	SALE	6	2026-08-10 11:04:00	3
4205	47	47	SALE	3	2026-08-11 09:53:00	3
4206	47	47	SALE	6	2026-08-12 11:40:00	3
4207	47	47	SALE	5	2026-08-13 10:56:00	3
4208	47	47	SALE	5	2026-08-14 16:57:00	3
4209	47	47	SALE	8	2026-08-15 18:34:00	3
4210	47	47	SALE	9	2026-08-16 11:06:00	3
4211	47	47	SALE	6	2026-08-17 19:12:00	3
4212	47	47	SALE	8	2026-08-18 13:33:00	3
4213	47	47	SALE	3	2026-08-19 15:10:00	3
4214	47	47	SALE	8	2026-08-20 18:34:00	3
4215	47	47	SALE	5	2026-08-21 14:47:00	3
4216	47	47	SALE	8	2026-08-22 16:50:00	3
4217	47	47	SALE	8	2026-08-23 20:43:00	3
4218	47	47	SALE	5	2026-08-24 18:28:00	3
4219	47	47	SALE	5	2026-08-25 12:48:00	3
4220	47	47	SALE	6	2026-08-26 15:55:00	3
4221	47	47	SALE	8	2026-08-27 12:55:00	3
4222	47	47	SALE	6	2026-08-28 17:15:00	3
4223	47	47	SALE	8	2026-08-29 10:54:00	3
4224	47	47	SALE	7	2026-08-30 17:11:00	3
4225	47	47	SALE	4	2026-08-31 17:43:00	3
4226	47	47	SALE	4	2026-09-01 14:26:00	3
4227	47	47	SALE	6	2026-09-02 09:21:00	3
4228	47	47	SALE	6	2026-09-03 12:36:00	3
4229	47	47	SALE	7	2026-09-04 16:47:00	3
4230	47	47	SALE	8	2026-09-05 09:31:00	3
4231	47	47	SALE	8	2026-09-06 20:37:00	3
4232	47	47	SALE	9	2026-09-07 17:46:00	3
4233	47	47	SALE	7	2026-09-08 19:27:00	3
4234	47	47	SALE	8	2026-09-09 15:43:00	3
4235	47	47	SALE	6	2026-09-10 10:29:00	3
4236	47	47	SALE	6	2026-09-11 16:44:00	3
4237	47	47	SALE	9	2026-09-12 09:25:00	3
4238	47	47	SALE	10	2026-09-13 16:15:00	3
4239	47	47	SALE	7	2026-09-14 15:33:00	3
4240	47	47	SALE	8	2026-09-15 11:55:00	3
4241	47	47	SALE	6	2026-09-16 09:23:00	3
4242	47	47	SALE	4	2026-09-17 09:24:00	3
4243	47	47	SALE	6	2026-09-18 17:09:00	3
4244	47	47	SALE	9	2026-09-19 10:42:00	3
4245	47	47	SALE	8	2026-09-20 11:11:00	3
4246	47	47	SALE	4	2026-09-21 12:40:00	3
4247	47	47	SALE	6	2026-09-22 14:20:00	3
4248	47	47	SALE	6	2026-09-23 19:10:00	3
4249	47	47	SALE	6	2026-09-24 10:25:00	3
4250	47	47	SALE	6	2026-09-25 19:55:00	3
4251	47	47	SALE	11	2026-09-26 19:23:00	3
4252	47	47	SALE	10	2026-09-27 09:49:00	3
4253	47	47	SALE	5	2026-09-28 14:34:00	3
4254	47	47	SALE	5	2026-09-29 16:59:00	3
4255	47	47	SALE	17	2026-09-30 10:43:00	3
4256	47	47	SALE	6	2026-10-01 13:25:00	3
4257	47	47	SALE	5	2026-10-02 18:09:00	3
4258	47	47	SALE	9	2026-10-03 20:04:00	3
4259	47	47	SALE	9	2026-10-04 17:41:00	3
4260	47	47	SALE	6	2026-10-05 11:04:00	3
4261	47	47	SALE	7	2026-10-06 18:08:00	3
4262	47	47	SALE	7	2026-10-07 14:36:00	3
4263	47	47	SALE	6	2026-10-08 15:29:00	3
4264	47	47	SALE	9	2026-10-09 18:02:00	3
4265	47	47	SALE	8	2026-10-10 17:37:00	3
4266	47	47	SALE	9	2026-10-11 17:49:00	3
4267	47	47	SALE	6	2026-10-12 19:17:00	3
4268	47	47	SALE	8	2026-10-13 12:27:00	3
4269	47	47	SALE	6	2026-10-14 18:38:00	3
4270	47	47	SALE	15	2026-10-15 17:18:00	3
4271	47	47	SALE	7	2026-10-16 17:55:00	3
4272	47	47	SALE	6	2026-10-17 09:10:00	3
4273	47	47	SALE	8	2026-10-18 11:57:00	3
4274	47	47	SALE	6	2026-10-19 09:54:00	3
4275	47	47	SALE	7	2026-10-20 14:51:00	3
4276	47	47	SALE	6	2026-10-21 09:38:00	3
4277	47	47	SALE	5	2026-10-22 20:46:00	3
4278	48	48	RECEIPT	1364	2026-07-25 08:00:00	2
4279	48	48	SALE	16	2026-07-25 17:28:00	3
4280	48	48	SALE	14	2026-07-26 13:19:00	3
4281	48	48	SALE	14	2026-07-27 11:08:00	3
4282	48	48	SALE	10	2026-07-28 16:45:00	3
4283	48	48	SALE	13	2026-07-29 14:32:00	3
4284	48	48	SALE	9	2026-07-30 14:47:00	3
4285	48	48	SALE	13	2026-07-31 19:17:00	3
4286	48	48	SALE	16	2026-08-01 17:40:00	3
4287	48	48	SALE	19	2026-08-02 14:46:00	3
4288	48	48	SALE	12	2026-08-03 18:27:00	3
4289	48	48	SALE	11	2026-08-04 14:50:00	3
4290	48	48	SALE	14	2026-08-05 14:50:00	3
4291	48	48	SALE	5	2026-08-06 20:53:00	3
4292	48	48	SALE	10	2026-08-07 18:18:00	3
4293	48	48	SALE	15	2026-08-08 11:32:00	3
4294	48	48	SALE	16	2026-08-09 11:19:00	3
4295	48	48	SALE	8	2026-08-10 18:58:00	3
4296	48	48	SALE	12	2026-08-11 10:05:00	3
4297	48	48	SALE	13	2026-08-12 20:27:00	3
4298	48	48	SALE	9	2026-08-13 14:01:00	3
4299	48	48	SALE	13	2026-08-14 11:59:00	3
4300	48	48	SALE	12	2026-08-15 09:56:00	3
4301	48	48	SALE	20	2026-08-16 09:02:00	3
4302	48	48	SALE	12	2026-08-17 11:51:00	3
4303	48	48	SALE	10	2026-08-18 13:23:00	3
4304	48	48	SALE	12	2026-08-19 19:14:00	3
4305	48	48	SALE	13	2026-08-20 18:41:00	3
4306	48	48	SALE	12	2026-08-21 12:04:00	3
4307	48	48	SALE	17	2026-08-22 12:08:00	3
4308	48	48	SALE	16	2026-08-23 19:56:00	3
4309	48	48	SALE	12	2026-08-24 10:51:00	3
4310	48	48	SALE	11	2026-08-25 14:55:00	3
4311	48	48	SALE	11	2026-08-26 14:04:00	3
4312	48	48	SALE	9	2026-08-27 12:00:00	3
4313	48	48	SALE	13	2026-08-28 14:21:00	3
4314	48	48	SALE	14	2026-08-29 16:02:00	3
4315	48	48	SALE	15	2026-08-30 17:13:00	3
4316	48	48	SALE	14	2026-08-31 19:40:00	3
4317	48	48	SALE	8	2026-09-01 15:35:00	3
4318	48	48	SALE	10	2026-09-02 20:11:00	3
4319	48	48	SALE	14	2026-09-03 19:06:00	3
4320	48	48	SALE	8	2026-09-04 13:19:00	3
4321	48	48	SALE	18	2026-09-05 13:54:00	3
4322	48	48	SALE	14	2026-09-06 17:33:00	3
4323	48	48	SALE	10	2026-09-07 18:24:00	3
4324	48	48	SALE	13	2026-09-08 15:37:00	3
4325	48	48	SALE	6	2026-09-09 18:45:00	3
4326	48	48	SALE	12	2026-09-10 16:09:00	3
4327	48	48	SALE	9	2026-09-11 16:54:00	3
4328	48	48	SALE	15	2026-09-12 20:59:00	3
4329	48	48	SALE	16	2026-09-13 12:27:00	3
4330	48	48	SALE	9	2026-09-14 16:57:00	3
4331	48	48	SALE	8	2026-09-15 19:50:00	3
4332	48	48	SALE	11	2026-09-16 16:46:00	3
4333	48	48	SALE	13	2026-09-17 13:41:00	3
4334	48	48	SALE	10	2026-09-18 15:09:00	3
4335	48	48	SALE	15	2026-09-19 20:00:00	3
4336	48	48	SALE	19	2026-09-20 11:23:00	3
4337	48	48	SALE	11	2026-09-21 17:47:00	3
4338	48	48	SALE	11	2026-09-22 20:10:00	3
4339	48	48	SALE	14	2026-09-23 14:18:00	3
4340	48	48	SALE	8	2026-09-24 12:04:00	3
4341	48	48	SALE	13	2026-09-25 17:13:00	3
4342	48	48	SALE	10	2026-09-26 11:45:00	3
4343	48	48	SALE	15	2026-09-27 17:51:00	3
4344	48	48	SALE	12	2026-09-28 10:47:00	3
4345	48	48	SALE	10	2026-09-29 11:12:00	3
4346	48	48	SALE	13	2026-09-30 10:08:00	3
4347	48	48	SALE	14	2026-10-01 12:38:00	3
4348	48	48	SALE	14	2026-10-02 11:56:00	3
4349	48	48	SALE	14	2026-10-03 19:00:00	3
4350	48	48	SALE	15	2026-10-04 19:19:00	3
4351	48	48	SALE	14	2026-10-05 18:05:00	3
4352	48	48	SALE	13	2026-10-06 09:24:00	3
4353	48	48	SALE	14	2026-10-07 20:00:00	3
4354	48	48	SALE	11	2026-10-08 10:33:00	3
4355	48	48	SALE	14	2026-10-09 12:26:00	3
4356	48	48	SALE	13	2026-10-10 13:31:00	3
4357	48	48	SALE	17	2026-10-11 11:13:00	3
4358	48	48	SALE	13	2026-10-12 20:35:00	3
4359	48	48	SALE	10	2026-10-13 16:22:00	3
4360	48	48	SALE	8	2026-10-14 09:34:00	3
4361	48	48	SALE	31	2026-10-15 11:49:00	3
4362	48	48	SALE	8	2026-10-16 16:25:00	3
4363	48	48	SALE	12	2026-10-17 17:45:00	3
4364	48	48	SALE	15	2026-10-18 10:42:00	3
4365	48	48	SALE	6	2026-10-19 16:11:00	3
4366	48	48	SALE	9	2026-10-20 11:57:00	3
4367	48	48	SALE	15	2026-10-21 14:30:00	3
4368	48	48	SALE	10	2026-10-22 16:20:00	3
4369	16	49	RECEIPT	9	2026-10-20 10:00:00	3
4370	11	50	RECEIPT	13	2026-10-20 10:00:00	3
4371	19	51	RECEIPT	12	2026-10-20 10:00:00	3
4372	20	52	RECEIPT	11	2026-10-20 10:00:00	3
4373	9	53	RECEIPT	14	2026-10-20 10:00:00	3
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: inv_admin
--

COPY public.users (user_id, name, email, role, password_hash) FROM stdin;
1	Admin User	admin@inventory.example	admin	$2b$12$ZlcX90/57eLZyB.b2Lrb1OAHpCA.YfBSIOEu4TJtbjIocwayeeJo6
2	Manager User	manager@inventory.example	manager	$2b$12$weprI38RVi3O6BLXL8Brp.3S12lVqu37TgdKHu4uQu84yL7pwgwh2
3	Staff User	staff@inventory.example	staff	$2b$12$lS5sIsSntC9wIO3qUt6MVuk3XpeOGZNGXLs0KdmV42B.QFAa0uiFK
\.


--
-- Name: alerts_alert_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.alerts_alert_id_seq', 11, true);


--
-- Name: categories_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.categories_category_id_seq', 6, true);


--
-- Name: demand_forecasts_forecast_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.demand_forecasts_forecast_id_seq', 1, false);


--
-- Name: products_product_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.products_product_id_seq', 48, true);


--
-- Name: purchase_orders_po_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.purchase_orders_po_id_seq', 1, false);


--
-- Name: stock_batches_batch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.stock_batches_batch_id_seq', 53, true);


--
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.suppliers_supplier_id_seq', 5, true);


--
-- Name: transactions_txn_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.transactions_txn_id_seq', 4373, true);


--
-- Name: users_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: inv_admin
--

SELECT pg_catalog.setval('public.users_user_id_seq', 3, true);


--
-- Name: alerts alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT alerts_pkey PRIMARY KEY (alert_id);


--
-- Name: categories categories_name_key; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_name_key UNIQUE (name);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (category_id);


--
-- Name: demand_forecasts demand_forecasts_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.demand_forecasts
    ADD CONSTRAINT demand_forecasts_pkey PRIMARY KEY (forecast_id);


--
-- Name: demand_forecasts demand_forecasts_product_id_forecast_date_model_used_key; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.demand_forecasts
    ADD CONSTRAINT demand_forecasts_product_id_forecast_date_model_used_key UNIQUE (product_id, forecast_date, model_used);


--
-- Name: po_items po_items_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_pkey PRIMARY KEY (po_id, product_id);


--
-- Name: product_suppliers product_suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.product_suppliers
    ADD CONSTRAINT product_suppliers_pkey PRIMARY KEY (product_id, supplier_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- Name: products products_sku_key; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (po_id);


--
-- Name: reorder_rules reorder_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.reorder_rules
    ADD CONSTRAINT reorder_rules_pkey PRIMARY KEY (product_id);


--
-- Name: stock_batches stock_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.stock_batches
    ADD CONSTRAINT stock_batches_pkey PRIMARY KEY (batch_id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (supplier_id);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (txn_id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: idx_alerts_open; Type: INDEX; Schema: public; Owner: inv_admin
--

CREATE INDEX idx_alerts_open ON public.alerts USING btree (is_resolved, created_at);


--
-- Name: idx_batch_expiry; Type: INDEX; Schema: public; Owner: inv_admin
--

CREATE INDEX idx_batch_expiry ON public.stock_batches USING btree (expiry_date);


--
-- Name: idx_batch_product; Type: INDEX; Schema: public; Owner: inv_admin
--

CREATE INDEX idx_batch_product ON public.stock_batches USING btree (product_id);


--
-- Name: idx_txn_product_time; Type: INDEX; Schema: public; Owner: inv_admin
--

CREATE INDEX idx_txn_product_time ON public.transactions USING btree (product_id, txn_time);


--
-- Name: transactions trg_after_txn; Type: TRIGGER; Schema: public; Owner: inv_admin
--

CREATE TRIGGER trg_after_txn AFTER INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION public.fn_after_txn();


--
-- Name: purchase_orders trg_po_received; Type: TRIGGER; Schema: public; Owner: inv_admin
--

CREATE TRIGGER trg_po_received AFTER UPDATE OF status ON public.purchase_orders FOR EACH ROW WHEN ((((old.status)::text IS DISTINCT FROM (new.status)::text) AND ((new.status)::text = 'RECEIVED'::text))) EXECUTE FUNCTION public.fn_po_received();


--
-- Name: alerts alerts_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT alerts_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: demand_forecasts demand_forecasts_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.demand_forecasts
    ADD CONSTRAINT demand_forecasts_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: po_items po_items_po_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(po_id) ON DELETE CASCADE;


--
-- Name: po_items po_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: product_suppliers product_suppliers_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.product_suppliers
    ADD CONSTRAINT product_suppliers_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: product_suppliers product_suppliers_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.product_suppliers
    ADD CONSTRAINT product_suppliers_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(supplier_id);


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(category_id);


--
-- Name: purchase_orders purchase_orders_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.users(user_id);


--
-- Name: purchase_orders purchase_orders_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(supplier_id);


--
-- Name: reorder_rules reorder_rules_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.reorder_rules
    ADD CONSTRAINT reorder_rules_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: stock_batches stock_batches_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.stock_batches
    ADD CONSTRAINT stock_batches_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: transactions transactions_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.stock_batches(batch_id);


--
-- Name: transactions transactions_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: transactions transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: inv_admin
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: TABLE alerts; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,INSERT ON TABLE public.alerts TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.alerts TO api_role;


--
-- Name: SEQUENCE alerts_alert_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.alerts_alert_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.alerts_alert_id_seq TO api_role;


--
-- Name: TABLE categories; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.categories TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.categories TO api_role;


--
-- Name: SEQUENCE categories_category_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.categories_category_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.categories_category_id_seq TO api_role;


--
-- Name: TABLE demand_forecasts; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.demand_forecasts TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.demand_forecasts TO api_role;


--
-- Name: SEQUENCE demand_forecasts_forecast_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.demand_forecasts_forecast_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.demand_forecasts_forecast_id_seq TO api_role;


--
-- Name: TABLE po_items; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,INSERT ON TABLE public.po_items TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.po_items TO api_role;


--
-- Name: TABLE product_suppliers; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.product_suppliers TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.product_suppliers TO api_role;


--
-- Name: TABLE products; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.products TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.products TO api_role;


--
-- Name: SEQUENCE products_product_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.products_product_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.products_product_id_seq TO api_role;


--
-- Name: TABLE purchase_orders; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,INSERT ON TABLE public.purchase_orders TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.purchase_orders TO api_role;


--
-- Name: SEQUENCE purchase_orders_po_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.purchase_orders_po_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.purchase_orders_po_id_seq TO api_role;


--
-- Name: TABLE reorder_rules; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.reorder_rules TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.reorder_rules TO api_role;


--
-- Name: TABLE stock_batches; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.stock_batches TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.stock_batches TO api_role;


--
-- Name: SEQUENCE stock_batches_batch_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.stock_batches_batch_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.stock_batches_batch_id_seq TO api_role;


--
-- Name: TABLE suppliers; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.suppliers TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.suppliers TO api_role;


--
-- Name: SEQUENCE suppliers_supplier_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.suppliers_supplier_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.suppliers_supplier_id_seq TO api_role;


--
-- Name: TABLE transactions; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.transactions TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.transactions TO api_role;
GRANT INSERT ON TABLE public.transactions TO staff_role;


--
-- Name: SEQUENCE transactions_txn_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT USAGE ON SEQUENCE public.transactions_txn_id_seq TO staff_role;
GRANT SELECT,USAGE ON SEQUENCE public.transactions_txn_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.transactions_txn_id_seq TO api_role;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.users TO api_role;


--
-- Name: SEQUENCE users_user_id_seq; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.users_user_id_seq TO agent_role;
GRANT SELECT,USAGE ON SEQUENCE public.users_user_id_seq TO api_role;


--
-- Name: TABLE v_current_stock; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.v_current_stock TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_current_stock TO api_role;
GRANT SELECT ON TABLE public.v_current_stock TO chat_role;
GRANT SELECT ON TABLE public.v_current_stock TO staff_role;


--
-- Name: TABLE v_daily_sales; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.v_daily_sales TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_daily_sales TO api_role;
GRANT SELECT ON TABLE public.v_daily_sales TO chat_role;


--
-- Name: TABLE v_daily_sales_full; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.v_daily_sales_full TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_daily_sales_full TO api_role;
GRANT SELECT ON TABLE public.v_daily_sales_full TO chat_role;


--
-- Name: TABLE v_near_expiry; Type: ACL; Schema: public; Owner: inv_admin
--

GRANT SELECT ON TABLE public.v_near_expiry TO agent_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_near_expiry TO api_role;
GRANT SELECT ON TABLE public.v_near_expiry TO chat_role;
GRANT SELECT ON TABLE public.v_near_expiry TO staff_role;


--
-- PostgreSQL database dump complete
--

\unrestrict gctp4mC3gOV0C5gedAZToCK15KE77suZmylTctcH1XvJzm4YmGOFbbBLbMpeYHM

