{% macro dv360_standard(source_name, table_name) %}
WITH dedupllicate_data AS (
    SELECT
        -- select dv360 standard data
        JSON_VALUE(data, "$.Advertiser Currency") AS advertiser_currency,
        JSON_VALUE(data, "$.CM360 Post-Click Revenue") AS cm360_post_click_revenue,
        JSON_VALUE(data, "$.CM360 Post-View Revenue") AS cm360_post_view_revenue,
        SAFE_CAST(JSON_VALUE(data, "$.Clicks") AS INT64) as clicks,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Complete Views (Video)']") AS INT64) AS video_completion,
        JSON_VALUE(data, "$.Creative") AS creative_name,
        FORMAT_DATE('%Y-%m-%d', safe.PARSE_DATE('%Y/%m/%d', JSON_VALUE(data, "$.Date"))) AS date, -- Convert date format
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['First-Quartile Views (Video)']") AS INT64) AS video_25_completion,
        JSON_VALUE(data, "$.Floodlight Activity ID") AS floodlight_activity_id,
        JSON_VALUE(data, "$.Floodlight Activity Name") AS floodlight_activity_name,
        SAFE_CAST(JSON_VALUE(data, "$.Impressions") AS INT64) AS impressions,
        JSON_VALUE(data, "$.Insertion Order") AS campaign_name,
        JSON_VALUE(data, "$.Insertion Order ID") AS campaign_id,
        JSON_VALUE(data, "$.Insertion Order Status") AS campaign_status,
        JSON_VALUE(data, "$.Line Item") AS line_item,
        JSON_VALUE(data, "$.Line Item ID") AS line_item_id,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Midpoint Views (Video)']") AS INT64) AS video_50_completion,
        JSON_VALUE(data, "$.Post-Click Conversions") AS post_click_conversions,
        JSON_VALUE(data, "$.Post-View Conversions") AS post_view_conversions,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Revenue (Adv Currency)']") AS FLOAT64)AS media_cost,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Third-Quartile Views (Video)']") AS INT64) AS video_75_completion,
        JSON_VALUE(data, "$.Total Conversions") AS total_conversions,
        ROW_NUMBER() OVER (
            PARTITION BY 
                FORMAT_DATE('%Y-%m-%d', safe.PARSE_DATE('%Y/%m/%d', JSON_VALUE(data, "$.Date"))), -- Use converted date
                JSON_VALUE(data, "$.Insertion Order ID"),
                JSON_VALUE(data, "$.Line Item ID"),
                JSON_VALUE(data, "$.Creative")
            ORDER BY 
                CAST(JSON_EXTRACT_SCALAR(data, "$['Revenue (Adv Currency)']") AS FLOAT64) DESC -- Keep the record with the highest revenue
        ) AS row_num
    FROM
        {{ source(source_name, table_name) }}
),final AS (
SELECT * ,
    CASE 
        WHEN SPLIT(campaign_name, '_')[OFFSET(3)] LIKE '%YT%' THEN 'Youtube Video'
        ELSE SPLIT(campaign_name, '_')[OFFSET(3)]
    END AS media_format,
    CASE 
        WHEN LOWER(campaign_name) LIKE '%nzme%' OR LOWER(creative_name) LIKE '%nzme%' THEN 'Nzme'
        WHEN LOWER(campaign_name) LIKE '%3now%' OR LOWER(campaign_name) LIKE '%three%'  OR LOWER(creative_name) LIKE '%3now%' OR LOWER(creative_name) LIKE '%three%' THEN 'Threenow'
        WHEN LOWER(campaign_name) LIKE '%youtube%' OR LOWER(creative_name) LIKE '%yt%' or lower(creative_name) LIKE '%yt%' or   LOWER(campaign_name) LIKE '%yt%' THEN 'Youtube'
        WHEN LOWER(campaign_name) LIKE '%TVNZ%' OR LOWER(creative_name) LIKE '%TVNZ%' or lower(creative_name) LIKE '%tvnz%' or   LOWER(campaign_name) LIKE '%tvnz%' THEN 'TVNZ'
        WHEN LOWER(campaign_name) LIKE '%metservice%' OR LOWER(creative_name) LIKE '%metservice%' THEN 'Metservice'
        WHEN LOWER(campaign_name) LIKE '%mediaworks%' OR LOWER(creative_name) LIKE '%mediaworks%' THEN 'MediaWorks'
        WHEN LOWER(campaign_name) LIKE '%business%' and LOWER(campaign_name) LIKE '%desk%' THEN 'Business Desk'
        WHEN LOWER(creative_name) LIKE '%business%' and LOWER(creative_name) LIKE '%desk%' THEN 'Business Desk'
        WHEN LOWER(campaign_name) LIKE '%acast%' OR LOWER(creative_name) LIKE '%acast%' THEN 'Acast'
        WHEN LOWER(campaign_name) LIKE '%perf%' AND LOWER(campaign_name) LIKE '%max%' OR LOWER(campaign_name) LIKE '%pmax%' THEN 'Performance Max'
        WHEN LOWER(campaign_name) LIKE '%stuff%' OR LOWER(creative_name) LIKE '%stuff%' THEN 'Stuff'
        ELSE 'Dv360'
    END AS publisher,
    CASE WHEN ARRAY_LENGTH(SPLIT(line_item, '_')) <8 THEN 'Other'
    ELSE SPLIT(line_item, '_')[OFFSET(7)] END AS audience_name,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name, '_')) < 8 THEN 'Other' ELSE SPLIT(creative_name, '_')[OFFSET(7)] END AS creative_descr,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name,'_'))>=8 THEN SPLIT(creative_name, '_')[OFFSET(5)] ELSE 'Other' END AS ad_format_detail,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name,'_'))>=8 THEN SPLIT(creative_name, '_')[OFFSET(6)] ELSE 'Other' END AS ad_format,
    CASE WHEN ARRAY_LENGTH(SPLIT(campaign_name,'_')) <=1 THEN 'Other'
    ELSE SPLIT(campaign_name,'_')[OFFSET(1)] END AS campaign_descr

FROM dedupllicate_data 
WHERE row_num = 1)
SELECT f.* 
from final f WHERE LOWER(campaign_name) not like '%yt%'

{% endmacro %}