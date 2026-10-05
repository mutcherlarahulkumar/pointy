/// The Pointy Parenting terms a parent accepts before linking a child. The
/// version must match the server's FamilyTermsVersion.
const familyTermsVersion = 'family-2026-10';

const familyTerms = <(String, String)>[
  (
    'Who can use Parenting',
    'You confirm that you are 18 or older and the parent or lawful guardian of the child you link, and that the child is under 18. '
        'An adult\'s account can never be turned into a child account, and a child account becomes an ordinary account by itself on the child\'s 18th birthday.'
  ),
  (
    'Your consent for your child\'s data',
    'Under India\'s Digital Personal Data Protection Act, 2023 (section 9), Pointy needs your verifiable consent to process your child\'s personal data. '
        'Accepting these terms with your PIN, and your child entering the code from your phone with their own PIN, is that consent. '
        'We keep a record of it (which terms, and when). You can withdraw it at any time by unlinking; the account then becomes an ordinary account.'
  ),
  (
    'What you will see and control',
    'You will see your child\'s balance and every payment they make or receive, and you set a daily and a monthly spending limit. '
        'A payment over a limit needs your approval: on your phone with your PIN, or with the one-time code your app shows for that child.'
  ),
  (
    'What Pointy will not do',
    'Pointy does not track, profile or show targeted suggestions or ads to children: on a child account there are no AI suggestions from time or place, '
        'no location is stored with payments, and no trip wallets or online shopping.'
  ),
  (
    'Limits for children\'s wallets',
    'Following the RBI rules for small prepaid wallets, a child account can hold at most ₹10,000, receive at most ₹10,000 a month, and pay at most ₹2,000 at a time. '
        'Children cannot add money with PayPal or withdraw (PayPal is for adults); you send pocket money from your balance instead.'
  ),
  (
    'Your responsibility',
    'You are responsible for the payments you approve and for keeping your PIN and phone safe. Do not share the approval code with anyone but your child. '
        'Pointy is a demo on PayPal\'s sandbox; this text is not legal advice.'
  ),
];
