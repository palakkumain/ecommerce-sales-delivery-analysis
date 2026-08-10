-- =====================================================================
-- E-Commerce Sales & Delivery Performance Analysis
-- Dataset: Olist Brazilian E-Commerce (real, ~99K orders, 2016-2018)
-- =====================================================================

-- Q1: Month-over-month revenue trend
-- Uses order_items joined to orders, filtered to delivered orders only,
-- since only delivered orders represent recognized revenue.
SELECT
    strftime('%Y-%m', o.order_purchase_timestamp) AS order_month,
    ROUND(SUM(oi.price), 2) AS revenue,
    COUNT(DISTINCT o.order_id) AS orders
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY order_month
ORDER BY order_month;


-- Q2: Revenue vs. order volume by product category (top 15)
-- Shows whether "most orders" and "most revenue" categories are the same.
SELECT
    COALESCE(ct.product_category_name_english, p.product_category_name, 'unknown') AS category,
    COUNT(DISTINCT oi.order_id) AS order_count,
    ROUND(SUM(oi.price), 2) AS revenue,
    ROUND(SUM(oi.price) / COUNT(DISTINCT oi.order_id), 2) AS avg_order_value
FROM order_items oi
JOIN orders o ON o.order_id = oi.order_id
JOIN products p ON p.product_id = oi.product_id
LEFT JOIN category_translation ct ON ct.product_category_name = p.product_category_name
WHERE o.order_status = 'delivered'
GROUP BY category
ORDER BY revenue DESC
LIMIT 15;


-- Q3: Average delivery time, and does late delivery correlate with review score?
-- Buckets orders into on-time vs. late (vs. estimated delivery date) and compares
-- average review score for each bucket.
SELECT
    CASE
        WHEN julianday(o.order_delivered_customer_date) > julianday(o.order_estimated_delivery_date)
            THEN 'late'
        ELSE 'on_time'
    END AS delivery_status,
    COUNT(*) AS order_count,
    ROUND(AVG(julianday(o.order_delivered_customer_date) - julianday(o.order_purchase_timestamp)), 1) AS avg_delivery_days,
    ROUND(AVG(r.review_score), 2) AS avg_review_score
FROM orders o
JOIN order_reviews r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY delivery_status;


-- Q4: Average order value by customer state (top 15 by AOV, min 30 orders)
SELECT
    c.customer_state,
    COUNT(DISTINCT o.order_id) AS order_count,
    ROUND(SUM(oi.price) / COUNT(DISTINCT o.order_id), 2) AS avg_order_value,
    ROUND(SUM(oi.price), 2) AS total_revenue
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state
HAVING COUNT(DISTINCT o.order_id) >= 30
ORDER BY avg_order_value DESC
LIMIT 15;


-- Q5: Repeat vs. one-time customers, and their average order value
-- Uses customer_unique_id since customer_id is order-scoped in this dataset,
-- while customer_unique_id identifies the actual person across orders.
WITH customer_order_counts AS (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id) AS orders_placed
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
customer_value AS (
    SELECT
        c.customer_unique_id,
        SUM(oi.price) AS total_spent
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
)
SELECT
    CASE WHEN coc.orders_placed > 1 THEN 'repeat' ELSE 'one_time' END AS customer_type,
    COUNT(*) AS customer_count,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customer_order_counts), 2) AS pct_of_customers,
    ROUND(AVG(cv.total_spent), 2) AS avg_lifetime_value
FROM customer_order_counts coc
JOIN customer_value cv ON cv.customer_unique_id = coc.customer_unique_id
GROUP BY customer_type;


-- Q6: Cohort retention - of customers who first ordered in month X,
-- what % placed another order in month X+1, X+2, X+3?
WITH first_order AS (
    SELECT
        c.customer_unique_id,
        MIN(strftime('%Y-%m', o.order_purchase_timestamp)) AS cohort_month
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
orders_with_cohort AS (
    SELECT
        c.customer_unique_id,
        fo.cohort_month,
        strftime('%Y-%m', o.order_purchase_timestamp) AS order_month,
        (CAST(strftime('%Y', o.order_purchase_timestamp) AS INT) - CAST(substr(fo.cohort_month,1,4) AS INT)) * 12
          + (CAST(strftime('%m', o.order_purchase_timestamp) AS INT) - CAST(substr(fo.cohort_month,6,2) AS INT)) AS month_offset
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN first_order fo ON fo.customer_unique_id = c.customer_unique_id
    WHERE o.order_status = 'delivered'
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_unique_id) AS cohort_size
    FROM first_order
    GROUP BY cohort_month
)
SELECT
    owc.cohort_month,
    cs.cohort_size,
    owc.month_offset,
    COUNT(DISTINCT owc.customer_unique_id) AS active_customers,
    ROUND(100.0 * COUNT(DISTINCT owc.customer_unique_id) / cs.cohort_size, 2) AS retention_pct
FROM orders_with_cohort owc
JOIN cohort_sizes cs ON cs.cohort_month = owc.cohort_month
WHERE owc.month_offset BETWEEN 0 AND 3
GROUP BY owc.cohort_month, owc.month_offset
ORDER BY owc.cohort_month, owc.month_offset;


-- Q7: Payment method popularity and its relationship to order value
SELECT
    op.payment_type,
    COUNT(*) AS payment_count,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM order_payments), 2) AS pct_of_payments,
    ROUND(AVG(op.payment_value), 2) AS avg_payment_value,
    ROUND(AVG(op.payment_installments), 1) AS avg_installments
FROM order_payments op
GROUP BY op.payment_type
ORDER BY payment_count DESC;


-- Q8: Average review score by product category - which categories underperform?
-- (min 50 reviews to avoid noise from tiny categories)
SELECT
    COALESCE(ct.product_category_name_english, p.product_category_name, 'unknown') AS category,
    COUNT(r.review_id) AS review_count,
    ROUND(AVG(r.review_score), 2) AS avg_review_score
FROM order_reviews r
JOIN orders o ON o.order_id = r.order_id
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p ON p.product_id = oi.product_id
LEFT JOIN category_translation ct ON ct.product_category_name = p.product_category_name
GROUP BY category
HAVING COUNT(r.review_id) >= 50
ORDER BY avg_review_score ASC
LIMIT 15;


-- Q9: % of orders delayed past estimated delivery date, by seller state
SELECT
    s.seller_state,
    COUNT(DISTINCT o.order_id) AS total_orders,
    SUM(CASE WHEN julianday(o.order_delivered_customer_date) > julianday(o.order_estimated_delivery_date)
             THEN 1 ELSE 0 END) AS delayed_orders,
    ROUND(100.0 * SUM(CASE WHEN julianday(o.order_delivered_customer_date) > julianday(o.order_estimated_delivery_date)
             THEN 1 ELSE 0 END) / COUNT(DISTINCT o.order_id), 2) AS pct_delayed
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN sellers s ON s.seller_id = oi.seller_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY s.seller_state
HAVING COUNT(DISTINCT o.order_id) >= 30
ORDER BY pct_delayed DESC;


-- Q10: Top 10 sellers by revenue, with their average review score
-- (window function used to rank sellers)
WITH seller_revenue AS (
    SELECT
        oi.seller_id,
        SUM(oi.price) AS total_revenue,
        COUNT(DISTINCT oi.order_id) AS order_count,
        RANK() OVER (ORDER BY SUM(oi.price) DESC) AS revenue_rank
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY oi.seller_id
),
seller_reviews AS (
    SELECT
        oi.seller_id,
        AVG(r.review_score) AS avg_review_score
    FROM order_items oi
    JOIN order_reviews r ON r.order_id = oi.order_id
    GROUP BY oi.seller_id
)
SELECT
    sr.seller_id,
    s.seller_state,
    sr.revenue_rank,
    ROUND(sr.total_revenue, 2) AS total_revenue,
    sr.order_count,
    ROUND(srev.avg_review_score, 2) AS avg_review_score
FROM seller_revenue sr
JOIN sellers s ON s.seller_id = sr.seller_id
LEFT JOIN seller_reviews srev ON srev.seller_id = sr.seller_id
WHERE sr.revenue_rank <= 10
ORDER BY sr.revenue_rank;
