-- DDL витрины данных
DROP TABLE IF EXISTS dwh.customer_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL, -- идентификатор записи
    customer_id BIGINT NOT NULL, -- идентификатор заказчика
    customer_name VARCHAR NOT NULL, -- Ф.И.О. заказчика
    customer_address VARCHAR NOT NULL, -- адрес заказчика
    customer_birthday DATE NOT NULL, -- дата рождения заказчика
    customer_email VARCHAR NOT NULL, -- электронная почтазаказчика
    customer_money NUMERIC(15,2) NOT NULL, -- сумма, которую потратил заказчик за месяц
    platform_money BIGINT NOT NULL, -- сумма, которую заработала платформа от покупок заказчика за месяц (10% от суммы, которую потратил заказчик)
    count_order BIGINT NOT NULL, -- количество заказов у заказчика за месяц
    avg_price_order NUMERIC(10,2) NOT NULL, -- средняя стоимость одного заказа у заказчика за месяц
    median_time_order_completed NUMERIC(10,1), -- медианное время в днях от момента создания заказа до его завершения за месяц
    top_product_category VARCHAR NOT NULL, -- самая популярная категория товаров у этого заказчика за месяц
    top_craftsman_id BIGINT NOT NULL, -- идентификатор самого популярного мастера ручной работы у заказчика
    count_order_created BIGINT NOT NULL, -- количество созданных заказов за месяц
    count_order_in_progress BIGINT NOT NULL, -- количество заказов в процессе изготовки за месяц
    count_order_delivery BIGINT NOT NULL, -- количество заказов в доставке за месяц
    count_order_done BIGINT NOT NULL, -- количество завершённых заказов за месяц
    count_order_not_done BIGINT NOT NULL, -- количество незавершённых заказов за месяц
    report_period VARCHAR NOT NULL, -- отчётный период год и месяц
    CONSTRAINT customer_report_datamart_pk PRIMARY KEY (id)
);

-- DDL таблицы инкрементальных загрузок
DROP TABLE IF EXISTS dwh.load_dates_customer_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.load_dates_customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    load_dttm DATE NOT NULL,
    CONSTRAINT load_dates_customer_report_datamart_pk PRIMARY KEY (id)
);


with

dwh_delta AS (
    SELECT     
       dcs.customer_id AS customer_id,
       dcs.customer_name AS customer_name,
       dcs.customer_address AS customer_address,
       dcs.customer_birthday AS customer_birthday,
       dcs.customer_email AS customer_email,
       fo.order_id AS order_id,
       dp.product_id AS product_id,
       dp.product_price AS product_price,
       dp.product_type AS product_type,
       dc.craftsman_id as craftsman_id,
       DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age,
       fo.order_completion_date - fo.order_created_date AS diff_order_date, 
       fo.order_status AS order_status,
       TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
       crd.customer_id AS exist_customer_id,
       dc.load_dttm AS craftsman_load_dttm,
       dcs.load_dttm AS customers_load_dttm,
       dp.load_dttm AS products_load_dttm
       FROM dwh.f_order fo 
           INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
           INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
           INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
           LEFT JOIN dwh.customer_report_datamart crd ON dcs.customer_id = crd.customer_id
                WHERE (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
                      (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
                      (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
                      (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart))
),

 -- ________________________________________________________________________


dwh_update_delta AS ( --По этим клиентам данные в витрине нужно будет обновить
    SELECT     
            dd.exist_customer_id AS customer_id
            FROM dwh_delta dd 
                WHERE dd.exist_customer_id IS NOT NULL        
),

 -- ________________________________________________________________________

dwh_delta_insert_result as (
   select
    	T5.customer_id AS customer_id,
        T5.customer_name AS customer_name,
        T5.customer_address AS customer_address,
        T5.customer_birthday AS customer_birthday,
        T5.customer_email AS customer_email,
        T5.customer_money AS customer_money,
        T5.platform_money AS platform_money,
        T5.count_order AS count_order,
        T5.avg_price_order AS avg_price_order,
        T5.median_time_order_completed AS median_time_order_completed,
        T5.product_type AS top_product_category,
        T5.craftsman_id as top_craftsman_id,
        T5.count_order_created AS count_order_created,
        T5.count_order_in_progress AS count_order_in_progress,
        T5.count_order_delivery AS count_order_delivery,
        T5.count_order_done AS count_order_done,
        T5.count_order_not_done AS count_order_not_done,
        T5.report_period AS report_period 
        
        from
           (
           select *,
           rank() over (partition by T2.customer_id order by T3.count_product desc) AS rank_count_product,
           rank() over (partition by T2.customer_id order by T4.count_craftsman_orders desc) AS rank_count_craftsman
		   from 

		   (SELECT 
           T1.customer_id AS customer_id,
           T1.customer_name AS customer_name,
           T1.customer_address AS customer_address,
           T1.customer_birthday AS customer_birthday,
           T1.customer_email AS customer_email,
           SUM(T1.product_price) AS customer_money,
           SUM(T1.product_price) * 0.1 AS platform_money,
           COUNT(order_id) AS count_order,
           AVG(T1.product_price) AS avg_price_order,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
           SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
           SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
           SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
           SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
           SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
           T1.report_period AS report_period
               FROM dwh_delta AS T1
               WHERE T1.exist_customer_id IS NULL
               GROUP BY T1.customer_id, T1.customer_name, T1.customer_address,
                        T1.customer_birthday, T1.customer_email, T1.report_period
               ) as T2
               
   inner join
   
   (SELECT
       dd.customer_id AS customer_id_for_product_type, 
       dd.product_type, 
       COUNT(dd.product_id) AS count_product
       FROM dwh_delta AS dd
       GROUP BY dd.customer_id, dd.product_type
       )
      as T3 on T3.customer_id_for_product_type = T2.customer_id
    
    inner join
    
    (SELECT    
       dd.customer_id AS customer_id_for_craftsman,
       dd.craftsman_id,
	   count(dd.order_id) as count_craftsman_orders
	   FROM dwh_delta as dd
       group by dd.customer_id, dd.craftsman_id
       )
       as T4 on T4.customer_id_for_craftsman = T2.customer_id)
       
       as T5 where  rank_count_product = 1 and rank_count_craftsman =1 order by report_period),
       
       
 -- ________________________________________________________________________

dwh_delta_update_result as (
   select
    	T5.customer_id AS customer_id,
        T5.customer_name AS customer_name,
        T5.customer_address AS customer_address,
        T5.customer_birthday AS customer_birthday,
        T5.customer_email AS customer_email,
        T5.customer_money AS customer_money,
        T5.platform_money AS platform_money,
        T5.count_order AS count_order,
        T5.avg_price_order AS avg_price_order,
        T5.median_time_order_completed AS median_time_order_completed,
        T5.product_type AS top_product_category,
        T5.craftsman_id as top_craftsman_id,
        T5.count_order_created AS count_order_created,
        T5.count_order_in_progress AS count_order_in_progress,
        T5.count_order_delivery AS count_order_delivery,
        T5.count_order_done AS count_order_done,
        T5.count_order_not_done AS count_order_not_done,
        T5.report_period AS report_period 
        
        from
           (
           select *,
           rank() over (partition by T2.customer_id order by T3.count_product desc) AS rank_count_product,
           rank() over (partition by T2.customer_id order by T4.count_craftsman_orders desc) AS rank_count_craftsman
		   from 

		   (SELECT 
           T1.customer_id AS customer_id,
           T1.customer_name AS customer_name,
           T1.customer_address AS customer_address,
           T1.customer_birthday AS customer_birthday,
           T1.customer_email AS customer_email,
           SUM(T1.product_price) AS customer_money,
           SUM(T1.product_price) * 0.1 AS platform_money,
           COUNT(order_id) AS count_order,
           AVG(T1.product_price) AS avg_price_order,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
           SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
           SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
           SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
           SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
           SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
           T1.report_period AS report_period
               FROM (
                                    SELECT     
                                            dcs.customer_id AS customer_id,
                                            dcs.customer_name AS customer_name,
                                            dcs.customer_address AS customer_address,
                                            dcs.customer_birthday AS customer_birthday,
                                            dcs.customer_email AS customer_email,
                                            fo.order_id AS order_id,
                                            dp.product_id AS product_id,
                                            dp.product_price AS product_price,
                                            dp.product_type AS product_type,
                                            DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age,
                                            fo.order_completion_date - fo.order_created_date AS diff_order_date,
                                            fo.order_status AS order_status, 
                                            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period
                                            FROM dwh.f_order fo 
                                                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
                                                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
                                                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                                INNER JOIN dwh_update_delta ud ON fo.customer_id = ud.customer_id
                                ) AS T1
                                    GROUP BY T1.customer_id, T1.customer_name, T1.customer_address,
                                             T1.customer_birthday, T1.customer_email, T1.report_period
                            ) AS T2 
                            inner join
   
   (SELECT
       dd.customer_id AS customer_id_for_product_type, 
       dd.product_type, 
       COUNT(dd.product_id) AS count_product
       FROM dwh_delta AS dd
       GROUP BY dd.customer_id, dd.product_type
       )
      as T3 on T3.customer_id_for_product_type = T2.customer_id
    
    inner join
    
    (SELECT    
       dd.customer_id AS customer_id_for_craftsman,
       dd.craftsman_id,
	   count(dd.order_id) as count_craftsman_orders
	   FROM dwh_delta as dd
       group by dd.customer_id, dd.craftsman_id
       )
       as T4 on T4.customer_id_for_craftsman = T2.customer_id)
       
       as T5 where  rank_count_product = 1 and rank_count_craftsman =1 order by report_period)
       ,
       
-- ________________________________________________________________________
       
 insert_delta AS ( -- выполняем insert новых расчитанных данных для витрины 
    INSERT INTO dwh.customer_report_datamart (
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period 
    ) SELECT 
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period 
            FROM dwh_delta_insert_result
),   

-- ________________________________________________________________________
       
update_delta AS ( -- выполняем обновление показателей в отчёте по уже существующим мастерам
UPDATE dwh.customer_report_datamart SET
        customer_name = updates.customer_name, 
        customer_address = updates.customer_address, 
        customer_birthday = updates.customer_birthday, 
        customer_email = updates.customer_email, 
        customer_money = updates.customer_money, 
        platform_money = updates.platform_money, 
        count_order = updates.count_order, 
        avg_price_order = updates.avg_price_order,
        median_time_order_completed = updates.median_time_order_completed, 
        top_product_category = updates.top_product_category, 
        top_craftsman_id = updates.top_craftsman_id,
        count_order_created = updates.count_order_created, 
        count_order_in_progress = updates.count_order_in_progress, 
        count_order_delivery = updates.count_order_delivery, 
        count_order_done = updates.count_order_done,
        count_order_not_done = updates.count_order_not_done, 
        report_period = updates.report_period
         
    FROM (
        SELECT 
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period 
            FROM dwh_delta_update_result) AS updates
    WHERE dwh.customer_report_datamart.customer_id = updates.customer_id
),

--____________________________________________________

insert_load_date AS ( -- делаем запись в таблицу загрузок о том, когда была совершена загрузка, чтобы в следующий раз взять данные, которые будут добавлены или изменены после этой даты
    INSERT INTO dwh.load_dates_customer_report_datamart (
        load_dttm
    )
    SELECT GREATEST(COALESCE(MAX(craftsman_load_dttm), NOW()), 
                    COALESCE(MAX(customers_load_dttm), NOW()), 
                    COALESCE(MAX(products_load_dttm), NOW())) 
        FROM dwh_delta
)
SELECT 'increment datamart'; -- инициализируем запрос CTE 


