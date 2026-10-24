/// German banks with a well-known FinTS address. Sparkassen and many others have one per
/// institute: their customers enter it (the bank's website lists it as "FinTS-/HBCI-Adresse").
class FintsBank {
  /// Bank key as in lib/data/repository.dart `bankAliases`.
  final String key;
  final String name;
  final String? blz;
  final String? url;
  const FintsBank(this.key, this.name, {this.blz, this.url});
}

const fintsBanks = [
  FintsBank('dkb', 'DKB', blz: '12030000', url: 'https://banking-dkb.s-fints-pt-dkb.de/fints30'),
  FintsBank('sparkasse', 'Sparkasse'),
  FintsBank('ing', 'ING', blz: '50010517', url: 'https://fints.ing.de/fints/'),
  FintsBank('comdirect', 'comdirect', blz: '20041111', url: 'https://fints.comdirect.de/fints'),
  FintsBank('consors', 'Consorsbank', blz: '76030080', url: 'https://brokerage-hbci.consorsbank.de/hbci'),
  FintsBank('vr', 'Volksbank / Raiffeisenbank', url: 'https://fints2.atruvia.de/cgi-bin/hbciservlet'),
  FintsBank('postbank', 'Postbank', url: 'https://hbci.postbank.de/banking/hbci.do'),
  FintsBank('deutsche', 'Deutsche Bank', url: 'https://fints.deutsche-bank.de/'),
  FintsBank('commerzbank', 'Commerzbank', url: 'https://fints.commerzbank.de/fints'),
  FintsBank('other', ''),
];
