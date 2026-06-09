-- Create a standardized view for Legacy ERP data
USE modern_erp;

DROP VIEW IF EXISTS vw_legacy_sales_standardized;

CREATE VIEW vw_legacy_sales_standardized AS
SELECT 
    -- Invoice identifiers
    h.sale_id AS invoice_id,
    h.bill_no AS invoice_number,
    
    -- Date standardization (convert to DATE only)
    DATE(h.sale_date) AS invoice_date,
    
    -- Branch standardization (map Airport Duty Free to HIA Duty Free)
    CASE 
        WHEN b.shop_name = 'Airport Duty Free' THEN 'HIA Duty Free'
        ELSE b.shop_name
    END AS branch_name,
    
    -- Branch type (keep as is)
    b.location_group AS branch_type,
    
    -- Payment method standardization (uppercase and trim)
    UPPER(TRIM(h.payment_mode)) AS payment_method,
    
    -- Sales amounts
    h.net_total AS final_amount,
    
    -- Product details
    i.product_code AS product_code,
    i.pcs AS quantity,
    
    -- Category standardization (map various text values to standard codes)
    CASE 
        WHEN UPPER(i.item_type) IN ('GOLD', 'G') THEN 'GOLD'
        WHEN UPPER(i.item_type) IN ('DIAMOND', 'DIA') THEN 'DIAMOND'
        WHEN UPPER(i.item_type) IN ('SILVER', 'SIL') THEN 'SILVER'
        ELSE UPPER(i.item_type)
    END AS category,
    
    -- Additional fields for analysis
    i.grams,
    i.rate,
    i.making_charge,
    i.line_total,
    
    -- Source system identifier
    'LEGACY' AS source_system,
    
    -- Status filter (exclude VOID)
    h.sale_status

FROM legacy_erp.legacy_sales_header h
INNER JOIN legacy_erp.legacy_sales_items i ON h.sale_id = i.sale_id
INNER JOIN legacy_erp.legacy_branch_master b ON h.shop_code = b.shop_code
WHERE h.sale_status != 'VOID';  -- Exclude void transactions

-- Verify the view
SELECT * FROM vw_legacy_sales_standardized;


-- Create payment aggregation view first (CRITICAL for avoiding double counting)
DROP VIEW IF EXISTS vw_payments_aggregated;

CREATE VIEW vw_payments_aggregated AS
SELECT 
    invoice_id,
    -- Concatenate multiple payment methods
    GROUP_CONCAT(DISTINCT UPPER(TRIM(payment_method)) ORDER BY payment_method SEPARATOR ', ') AS payment_methods,
    -- Count number of payment transactions
    COUNT(*) AS payment_count,
    -- Sum of all payments
    SUM(payment_amount) AS total_paid,
    -- Flag for mixed payments
    CASE 
        WHEN COUNT(*) > 1 THEN 'MIXED'
        WHEN COUNT(*) = 1 THEN 'SINGLE'
        ELSE 'NO_PAYMENT'
    END AS payment_type,
    -- Primary payment method (first one alphabetically for reporting)
    MIN(UPPER(TRIM(payment_method))) AS primary_payment_method
FROM modern_erp.invoice_payments
GROUP BY invoice_id;

-- Verify payment aggregation
SELECT * FROM vw_payments_aggregated;


-- Create standardized view for Modern ERP data
DROP VIEW IF EXISTS vw_modern_sales_standardized;

CREATE VIEW vw_modern_sales_standardized AS
SELECT 
    -- Invoice identifiers
    m.invoice_id,
    TRIM(m.invoice_number) AS invoice_number,
    
    -- Date (already in correct format)
    m.invoice_date,
    
    -- Branch information (already standardized in modern system)
    b.branch_name,
    b.branch_type,
    
    -- Payment information from aggregated view
    COALESCE(p.primary_payment_method, 'UNKNOWN') AS payment_method,
    COALESCE(p.payment_type, 'NO_PAYMENT') AS payment_type_flag,
    p.payment_count,
    
    -- Sales amount
    m.final_amount,
    
    -- Product details
    d.sku AS product_code,
    p_d.product_name,
    d.qty AS quantity,
    
    -- Category standardization (map codes to full names)
    CASE 
        WHEN p_d.category_code = 'G' THEN 'GOLD'
        WHEN p_d.category_code = 'DIA' THEN 'DIAMOND'
        WHEN p_d.category_code = 'SIL' THEN 'SILVER'
        ELSE p_d.category_code
    END AS category,
    
    -- Additional product attributes
    p_d.purity,
    d.gross_weight,
    d.net_weight,
    d.unit_price,
    d.mc_value AS making_charge,
    d.total_price AS line_total,
    
    -- Source system identifier
    'MODERN' AS source_system,
    
    -- Status filter (exclude CANCELLED)
    m.invoice_status

FROM modern_erp.invoice_master m
INNER JOIN modern_erp.invoice_details d ON m.invoice_id = d.invoice_id
INNER JOIN modern_erp.product_master p_d ON d.product_id = p_d.product_id
INNER JOIN modern_erp.branch_master b ON m.branch_id = b.branch_id
LEFT JOIN vw_payments_aggregated p ON m.invoice_id = p.invoice_id
WHERE m.invoice_status != 'CANCELLED';  -- Exclude cancelled transactions

-- Verify the view
SELECT * FROM vw_modern_sales_standardized;                                     

-- Create the final unified view combining both systems
DROP VIEW IF EXISTS vw_unified_sales_final;

CREATE VIEW vw_unified_sales_final AS
SELECT 
    invoice_id,
    invoice_number,
    invoice_date,
    branch_name,
    branch_type,
    payment_method,
    final_amount,
    product_code,
    quantity,
    category,
    source_system,
    -- Include legacy-specific fields (NULL for modern)
    grams,
    rate,
    making_charge,
    line_total
FROM vw_legacy_sales_standardized

UNION ALL

SELECT 
    invoice_id,
    invoice_number,
    invoice_date,
    branch_name,
    branch_type,
    payment_method,
    final_amount,
    product_code,
    quantity,
    category,
    source_system,
    -- Modern-specific fields mapped to legacy structure
    gross_weight AS grams,
    unit_price AS rate,
    making_charge,
    line_total
FROM vw_modern_sales_standardized;

-- Verify unified view
SELECT 
    source_system,
    COUNT(*) as record_count,
    MIN(invoice_date) as earliest_date,
    MAX(invoice_date) as latest_date,
    SUM(final_amount) as total_sales
FROM vw_unified_sales_final
GROUP BY source_system;

-- View for mixed payment analysis
DROP VIEW IF EXISTS vw_mixed_payment_analysis;

CREATE VIEW vw_mixed_payment_analysis AS
SELECT 
    m.invoice_id,
    m.invoice_number,
    m.invoice_date,
    b.branch_name,
    m.final_amount,
    p.payment_type,
    p.payment_count,
    p.payment_methods,
    p.primary_payment_method
FROM modern_erp.invoice_master m
INNER JOIN modern_erp.branch_master b ON m.branch_id = b.branch_id
INNER JOIN vw_payments_aggregated p ON m.invoice_id = p.invoice_id
WHERE m.invoice_status != 'CANCELLED'
    AND p.payment_type = 'MIXED';