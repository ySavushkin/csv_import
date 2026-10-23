public with sharing class ImportQueueable implements Queueable {

    public void execute(QueueableContext context) {
        List<ContentVersion> pendingChunks = [
            SELECT Id
            , Title
            , VersionData 
            FROM ContentVersion 
            WHERE Processing_Status__c = 'Pending' 
            ORDER BY Title ASC 
            LIMIT 1
        ];

        if(pendingChunks.isEmpty()) {
            System.debug('All files are processed successfully!');
            return;
        }

        ContentVersion currentChunk = pendingChunks.get(0);

        try {
            if(currentChunk.Title.containsIgnoreCase('product')) {
                processProducts(currentChunk.VersionData);
            } else if(currentChunk.Title.containsIgnoreCase('customer')) {
                processContacts(currentChunk.VersionData);
            } else if(currentChunk.Title.containsIgnoreCase('order')) {
                processOrdersAndItems(currentChunk.VersionData);
            }

            update new ContentVersion(
                Id = currentChunk.Id,
                Processing_Status__c = 'Completed'
            );

        } catch(Exception e) {
            System.debug('Error : ' + currentChunk.Title + ': ' + e.getMessage());
            update new ContentVersion(
                Id = currentChunk.Id,
                Processing_Status__c = 'Failed',
                Error_Message__c = e.getMessage()
            );
        }

        System.enqueueJob(new ChunkImportQueueable());
    }

    private void processProducts(Blob csvBlob) {
        List<String> lines = parseCsvLines(csvBlob);
        if(lines.size() <= 1) {
            return;
        }

        Map<String, Integer> headerMap = getHeaderMap(lines.get(0));
        List<Product2> productsToUpsert = new List<Product2>();

        for(Integer i = 1; i < lines.size(); i++) {
            List<String> columns = parseCsvRow(lines.get(i));

            if(columns.isEmpty()) {
                continue;
            }

            String sku = getValue(columns, headerMap, 'SKU');
            String name = getValue(columns, headerMap, 'Name');

            productsToUpsert.add(new Product2(
                StockKeepingUnit = sku,
                Name = String.isNotBlank(name) ? name : sku,
                Product_External_Id__c = sku,
                IsActive = true
            ));
        }

        if(!productsToUpsert.isEmpty()) {
            upsert productsToUpsert Product2.fields.Product_External_Id__c;

            Id standardPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

            List<PricebookEntry> pbentriesToInsertList = new List<PricebookEntry>();
            for(Product2 product_i : productsToUpsert) {
                if(product_i.Id != null) {
                    pbentriesToInsertList.add(new PricebookEntry(
                        Pricebook2Id = standardPricebookId,
                        Product2Id = product_i.Id,
                        UnitPrice = 0,
                        IsActive = true,
                        UseStandardPrice = false
                    ));
                }
            }

            if(!pbentriesToInsertList.isEmpty()) {
                Database.insert(pbentriesToInsertList, false);
            }
        }
    }

    private void processContacts(Blob csvBlob) {
        List<String> lines = parseCsvLines(csvBlob);
        if(lines.size() <= 1) {
            return;
        }

        Map<String, Integer> headerMap = getHeaderMap(lines.get(0));
        Id personAccountRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('PersonAccount').getRecordTypeId();

        List<Account> accountsToUpsertList = new List<Account>();

        for(Integer i = 1; i < lines.size(); i++) {
            List<String> columns = parseCsvRow(lines.get(i));

            if(columns.isEmpty()) {
                continue;
            }

            String externalId = getValue(columns, headerMap, 'External_Customer_ID');
            String name = getValue(columns, headerMap, 'Name');
            String email = getValue(columns, headerMap, 'Email');
            String address = getValue(columns, headerMap, 'Adress');

            if(String.isNotBlank(externalId)) {
                accountsToUpsertList.add(new Account(
                    RecordTypeId = personAccountRecordTypeId,
                    Customer_External_Id__c = externalId,
                    LastName = name,
                    PersonEmail = email,
                    PersonMailingStreet = address
                ));
            }
        }

        if(!accountsToUpsertList.isEmpty()) {
            upsert accountsToUpsertList Account.fields.Customer_External_Id__c;
        }
    }

    private void processOrdersAndItems(Blob csvBlob) {
        List<String> lines = parseCsvLines(csvBlob);
        if(lines.size() <= 1) {
            return;
        }

        Map<String, Integer> headerMap = getHeaderMap(lines.get(0));
        
        Map<String, Order> incomingOrdersMap = new Map<String, Order>();
        List<OrderItemRawWrapper> rawItemsList = new List<OrderItemRawWrapper>();
        Set<String> skusSet = new Set<String>();

        Id standardPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        for(Integer i = 1; i < lines.size(); i++) {
            List<String> columns = parseCsvRow(lines.get(i));
            if(columns.isEmpty()) {
                continue;
            }

            String orderNum = getValue(columns, headerMap, 'OrderNumber');
            String customerExtId = getValue(columns, headerMap, 'External_Customer_ID');
            String lineItem = getValue(columns, headerMap, 'OrderLineItem');
            String sku = getValue(columns, headerMap, 'SKU');
            String qtyStr = getValue(columns, headerMap, 'Quantity');
            String priceStr = getValue(columns, headerMap, 'Price');

            if(String.isBlank(orderNum)) {
                continue;
            }

            if(!incomingOrdersMap.containsKey(orderNum)) {
                incomingOrdersMap.put(orderNum, new Order(
                    Order_External_Id__c = orderNum,
                    Status = 'Draft',
                    EffectiveDate = Date.today(),
                    Pricebook2Id = standardPricebookId,
                    Account = new Account(Customer_External_Id__c = customerExtId)
                ));
            }

            if(String.isNotBlank(sku)) {
                skusSet.add(sku);
                OrderItemRawWrapper itemRaw = new OrderItemRawWrapper();
                itemRaw.orderNumber = orderNum;
                itemRaw.orderLineItem = lineItem;
                itemRaw.sku = sku;
                itemRaw.quantity = String.isNotBlank(qtyStr) ? Decimal.valueOf(qtyStr) : 1;
                itemRaw.unitPrice = String.isNotBlank(priceStr) ? Decimal.valueOf(priceStr) : 0;
                rawItemsList.add(itemRaw);
            }
        }

        Map<String, Order> existingOrdersMap = new Map<String, Order>();
        
        for(Order existingOrder : [SELECT Id, Order_External_Id__c FROM Order WHERE Order_External_Id__c IN :incomingOrdersMap.keySet()]) {
            existingOrdersMap.put(existingOrder.Order_External_Id__c, existingOrder);
        }

        List<Order> ordersToUpsertList = new List<Order>();
        for(String orderNum : incomingOrdersMap.keySet()) {
            if(!existingOrdersMap.containsKey(orderNum)) {
                ordersToUpsertList.add(incomingOrdersMap.get(orderNum));
            }
        }

        if (!ordersToUpsertList.isEmpty()) {
            upsert ordersToUpsertList Order.fields.Order_External_Id__c;
        }

        if (!rawItemsList.isEmpty() && !skusSet.isEmpty()) {
            Map<String, Id> skuToPbeMap = new Map<String, Id>();
            for (PricebookEntry pbe : [
                SELECT Id
                , Product2.StockKeepingUnit 
                FROM PricebookEntry 
                WHERE Pricebook2Id = :standardPricebookId 
                AND Product2.StockKeepingUnit IN :skusSet 
                AND IsActive = true
            ]) {
                skuToPbeMap.put(pbe.Product2.StockKeepingUnit, pbe.Id);
            }

            List<OrderItem> itemsToUpsert = new List<OrderItem>();
            for (OrderItemRawWrapper raw : rawItemsList) {
                Id pbeId = skuToPbeMap.get(raw.sku);
                if (pbeId != null) {
                    itemsToUpsert.add(new OrderItem(
                        OrderItem_External_Id__c = raw.orderNumber + '_' + raw.orderLineItem,
                        Quantity = raw.quantity,
                        UnitPrice = raw.unitPrice,
                        PricebookEntryId = pbeId,
                        Order = new Order(Order_External_Id__c = raw.orderNumber)
                    ));
                }
            }

            if (!itemsToUpsert.isEmpty()) {
                upsert itemsToUpsert OrderItem.fields.OrderItem_External_Id__c;
            }
        }
    }

    private List<String> parseCsvLines(Blob csvBlob) {
        String csvContent = csvBlob.toString();
        return csvContent.split('\r?\n');
    }

    private Map<String, Integer> getHeaderMap(String headerLine) {
        Map<String, Integer> headerMap = new Map<String, Integer>();
        List<String> headers = parseCsvRow(headerLine);
        for (Integer i = 0; i < headers.size(); i++) {
            headerMap.put(headers.get(i).trim(), i);
        }
        return headerMap;
    }

    private String getValue(List<String> columns, Map<String, Integer> headerMap, String fieldName) {
        if (headerMap.containsKey(fieldName)) {
            Integer index = headerMap.get(fieldName);
            if (index < columns.size()) {
                return columns.get(index).trim();
            }
        }
        return null;
    }

    private List<String> parseCsvRow(String row) {
        if (String.isBlank(row)) return new List<String>();
        return row.split(',', -1);
    }

    private class OrderItemRawWrapper {
        public String orderNumber;
        public String orderLineItem;
        public String sku;
        public Decimal quantity;
        public Decimal unitPrice;
    }
}