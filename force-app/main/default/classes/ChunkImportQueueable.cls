public with sharing class ChunkImportQueueable implements Queueable {

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

        if (pendingChunks.isEmpty()) {
            System.debug('All files are processed successfully!');
            return;
        }

        ContentVersion currentChunk = pendingChunks.get(0);

        try {
            if (currentChunk.Title.containsIgnoreCase('product')) {
                processProducts(currentChunk.VersionData);
            } else if (currentChunk.Title.containsIgnoreCase('customer')) {
                processContacts(currentChunk.VersionData);
            } else if (currentChunk.Title.containsIgnoreCase('order')) {
                processOrdersAndItems(currentChunk.VersionData);
            }

            update new ContentVersion(
                Id = currentChunk.Id,
                Processing_Status__c = 'Completed'
            );

        } catch (Exception e) {
            System.debug('Error : ' + currentChunk.Title + ': ' + e.getMessage());
            update new ContentVersion(
                Id = currentChunk.Id,
                Processing_Status__c = 'Failed',
                Error_Message__c = e.getMessage()
            );
        }

        if (!Test.isRunningTest()) {
            System.enqueueJob(new ChunkImportQueueable());
        }
    }

    private void processProducts(Blob csvBlob) {
        DataWeave.Script dwScript = new DataWeaveScriptResource.csvToProducts();
        DataWeave.Result dwresult = dwScript.execute(new Map<String, Object>{'records' => csvBlob});
        
        List<Product2> productList = (List<Product2>) dwresult.getValue();
        if (!productList.isEmpty()) {
            upsert productList Product2.fields.Product_External_Id__c;

            Id standardPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

            List<PricebookEntry> pbesToUpsert = new List<PricebookEntry>();
            for (Product2 p : productList) {
                if (p.Id != null) {
                    pbesToUpsert.add(new PricebookEntry(
                        Pricebook2Id = standardPricebookId,
                        Product2Id = p.Id,
                        UnitPrice = 0,
                        IsActive = true,
                        UseStandardPrice = false
                    ));
                }
            }

            if (!pbesToUpsert.isEmpty()) {
                Database.insert(pbesToUpsert, false);
            }
        }
    }

    private void processContacts(Blob csvBlob) {
        DataWeave.Script dwScript = new DataWeaveScriptResource.csvToAccounts();
        DataWeave.Result dwresult = dwScript.execute(new Map<String, Object>{'records' => csvBlob});
        
        List<Account> contactList = (List<Account>) dwresult.getValue();
        if (!contactList.isEmpty()) {
            Id personAccountRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount')
            .getRecordTypeId();

            for (Account acc : contactList) {
                acc.RecordTypeId = personAccountRecordTypeId;
            }
            
            upsert contactList Account.fields.Customer_External_Id__c;
        }
    }

    private void processOrdersAndItems(Blob csvBlob) {
        DataWeave.Script dwScript = new DataWeaveScriptResource.csvToOrders();
        DataWeave.Result dwresult = dwScript.execute(new Map<String, Object>{'records' => csvBlob});
        
        OrderImportWrapper orderWrapper = (OrderImportWrapper) dwresult.getValue();
        if (orderWrapper == null) return;

        Id standardPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        List<Order> ordersToUpsert = new List<Order>();
        if (orderWrapper.orders != null) {
            for (OrderImportWrapper.OrderRow row : orderWrapper.orders) {
                ordersToUpsert.add(new Order(
                    Order_External_Id__c = row.orderNumber,
                    Status = 'Draft',
                    EffectiveDate = Date.today(),
                    Pricebook2Id = standardPricebookId,
                    Account = new Account(Customer_External_Id__c = row.customerExternalId)
                ));
            }
        }

        if (!ordersToUpsert.isEmpty()) {
            upsert ordersToUpsert Order.fields.Order_External_Id__c;
        }

        List<OrderItem> itemsToUpsert = new List<OrderItem>();
        if (orderWrapper.orderItems != null) {

            Set<String> SKUs = new Set<String>();
            for(OrderImportWrapper.OrderItemRow row_i : orderWrapper.orderItems) {
                if(String.isNotBlank(row_i.sku)) {
                    SKUs.add(row_i.sku);
                }
            }

            Map<String, Id> skuToPricebookEntryIdMap = new Map<String, Id>();
            for (PricebookEntry pbEntry : [
                        SELECT Id
                        , Product2.StockKeepingUnit 
                        FROM PricebookEntry 
                        WHERE Pricebook2Id = :standardPricebookId 
                        AND Product2.StockKeepingUnit IN :SKUs 
                        AND IsActive = true
            ]) {
                skuToPricebookEntryIdMap.put(pbEntry.Product2.StockKeepingUnit, pbEntry.Id);
            }

            for (OrderImportWrapper.OrderItemRow row_j : orderWrapper.orderItems) {
                Id pbEntryId = skuToPricebookEntryIdMap.get(row_j.sku);

                if(pbEntryId != null) {
                    itemsToUpsert.add(new OrderItem(
                        OrderItem_External_Id__c = row_j.orderNumber + '_' + row_j.orderLineItem,
                        Quantity = row_j.quantity,
                        UnitPrice = row_j.price,
                        PricebookEntryId = pbEntryId,
                        Order = new Order(Order_External_Id__c = row_j.orderNumber)
                    ));
                }
            }
        }

        if (!itemsToUpsert.isEmpty()) {
            upsert itemsToUpsert OrderItem.fields.OrderItem_External_Id__c;
        }
    }
}