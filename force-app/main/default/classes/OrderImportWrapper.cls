public with sharing class OrderImportWrapper {
    public List<OrderRow> orders;
    public List<OrderItemRow> orderItems;

    public class OrderRow {
        public String orderNumber;
        public String customerExternalId;
    }

    public class OrderItemRow {
        public String orderNumber;
        public String orderLineItem;
        public Decimal quantity;
        public Decimal price;
        public String sku;
    }
}