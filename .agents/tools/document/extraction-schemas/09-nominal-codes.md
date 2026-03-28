# Nominal Code Auto-Categorisation

When `nominal_code` is not extracted from the document, infer from context:

| Merchant/Item Pattern | Nominal Code | Category |
|----------------------|-------------|----------|
| Amazon, Staples, office supplies | 7504 | Stationery & Office Supplies |
| Shell, BP, Esso, fuel, petrol, diesel | 7401 | Motor Expenses - Fuel |
| Hotel, Airbnb, accommodation | 7403 | Hotel & Accommodation |
| Restaurant, cafe, food, lunch | 7402 | Subsistence |
| Train, bus, taxi, Uber, parking | 7400 | Travel & Subsistence |
| Royal Mail, DHL, FedEx, postage | 7501 | Postage & Shipping |
| BT, Vodafone, phone, broadband | 7502 | Telephone & Internet |
| Adobe, Microsoft, SaaS, subscription | 7404 | Computer Software |
| Google Ads, Facebook Ads, marketing | 6201 | Advertising & Marketing |
| Accountant, solicitor, legal | 7600 | Professional Fees |
| Plumber, electrician, repair | 7300 | Repairs & Maintenance |
| *Default (no match)* | 5000 | General Purchases |
