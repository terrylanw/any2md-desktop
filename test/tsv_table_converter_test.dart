import 'package:any2md_desktop/features/workspace/tsv_table_converter.dart';
import 'package:flutter_test/flutter_test.dart';

const _sample = '''英文\t印地\t乌尔都\t孟加拉\tID\tVI\tMS\tTH\tFIL\tTA\tAR
OK\tठीक\tٹھیک\tঠিক আছে\tOK\tOK\tOK\tโอเค\tOK lang\tசரி\tحسنا
Cancel\tरद्द\tمنسوخ\tবাতিল\tBatalkan\tHủy bỏ\tBatal\tยกเลิก\tKanselahin\tரத்துசெய்\tإلغاء
Confirm\tपुष्टि\tتصدیق\tনিশ্চিত\tKonfirmasi\tXác nhận\tSahkan\tยืนยัน\tKumpirmahin\tஉறுதிப்படுத்தவும்\tتأكيد
Close\tबंद\tبند\tবন্ধ\tTutup\tĐóng\tTutup\tปิด\tIsara\tமூடு\tإغلاق
Rules\tनियम\tقواعد\tনিয়ম\tAturan\tQuy tắc\tPeraturan\tกฎเกณฑ์\tMga panuntunan\tவிதிகள்\tالقواعد
This activity is not affiliated with Google or Apple Inc. All rights are reserved by Haco.\tयह गतिविधि Google या Apple Inc. से संबद्ध नहीं है। सभी अधिकार Haco के पास सुरक्षित हैं।\tیہ سرگرمی Google یا Apple Inc. سے وابستہ نہیں ہے۔ تمام حقوق Haco کے پاس محفوظ ہیں۔\tএই অ্যাক্টিভিটি Google বা Apple Inc.-এর সাথে সম্পর্কিত নয়। সর্বস্বত্ব Haco কর্তৃক সংরক্ষিত।\tAktivitas ini tidak berafiliasi dengan Google atau Apple Inc. Semua hak dilindungi Haco.\tHoạt động này không liên kết với Google hoặc Apple Inc. Mọi quyền thuộc về Haco.\tAktiviti ini tidak berkaitan dengan Google atau Apple Inc. Semua hak terpelihara oleh Haco.\tกิจกรรมนี้ไม่มีส่วนเกี่ยวข้องกับ Google หรือ Apple Inc. สงวนลิขสิทธิ์ทั้งหมดโดย Haco\tAng aktibidad na ito ay hindi kaakibat ng Google o Apple Inc. Nakalaan sa Haco ang lahat ng karapatan.\tஇந்த செயல்பாடு Google அல்லது Apple Inc. உடன் தொடர்புடையது அல்ல. அனைத்து உரிமைகளும் Haco-க்கு உரியவை.\tهذا النشاط غير تابع لشركة Google أو Apple Inc. جميع الحقوق محفوظة لدى Haco.
Vehicle\tव्हीकल\tگاڑی\tগাড়ি\tKendaraan\tXe\tKenderaan\tยานพาหนะ\tSasakyan\tவாகனம்\tمركبة
Coins\tकॉइन्स\tسکے\tকয়েন\tKoin\tTiền xu\tSyiling\tเหรียญ\tMga barya\tநாணயங்கள்\tعملات معدنية
Frame\tअवतार फ़्रेम\tاوتار فریم\tঅবতার ফ্রেম\tBingkai\tKhung\tBingkai\tกรอบ\tFrame\tசட்டகம்\tالإطار
Theme\tरूम थीम\tروم تھیم\tরুম থিম\tTema\tChủ đề\tTema\tธีม\tTema\tதீம்\tالموضوع
Reward\tरिवॉर्ड\tانعام\tপুরস্কার\tHadiah\tPhần thưởng\tGanjaran\tรางวัล\tGantimpala\tவெகுமதி\tمكافأة
Gift\tगिफ़्ट\tتحفہ\tউপহার\tHadiah\tQuà tặng\tHadiah\tของขวัญ\tRegalo\tபரிசு\tهدية
Others\tअन्य\tدیگر\tঅন্যান্য\tLainnya\tNhững người khác\tLain-lain\tอื่นๆ\tIba pa\tமற்றவை\tآخرون
EXP\tअनुभव\tتجربہ\tঅভিজ্ঞতা\tEXP\tEXP\tEXP\tEXP\tEXP\tEXP\tEXP
Vehicle\tवाहन\tگاڑی\tযানবাহন\tKendaraan\tXe\tKenderaan\tยานพาหนะ\tSasakyan\tவாகனம்\tمركبة
Custom_ID\tकस्टम आईडी\tکسٹم آئی ڈی\tকাস্টম আইডি\tID Khusus\tID tùy chỉnh\tID Tersuai\tID แบบกำหนดเอง\tCustom ID\tதனிப்பயன் ID\tمعرّف مخصص
Entrance\tप्रवेश\tداخلہ\tপ্রবেশ\tPintu masuk\tLối vào\tPintu masuk\tทางเข้า\tPagpasok\tநுழைவு\tمدخل
ProfileCard\tप्रोफाइल कार्ड\tپروفائل کارڈ\tপ্রোফাইল কার্ড\tKartu Profil\tThẻ hồ sơ\tKad Profil\tการ์ดโปรไฟล์\tProfile Card\tசுயவிவர அட்டை\tبطاقة الملف الشخصي
ChatBubble\tचैट बबल\tچیٹ ببل\tচ্যাট বাবল\tGelembung Chat\tBong bóng trò chuyện\tGelembung Sembang\tฟองแชท\tChat Bubble\tஅரட்டை குமிழி\tفقاعة الدردشة
MicWave\tमाइक वेव\tمائیک ویو\tমাইক ওয়েভ\tGelombang Mikrofon\tSóng mic\tGelombang Mikrofon\tคลื่นไมค์\tMic Wave\tமைக் அலை\tموجة الميكروفون
MicSkin\tमाइक स्किन\tمائیک اسکِن\tমাইক স্কিন\tTampilan Mikrofon\tGiao diện mic\tKulit Mikrofon\tสกินไมค์\tMic Skin\tமைக் ஸ்கின்\tمظهر الميكروفون
RoomFrame\tरूम फ्रेम\tروم فریم\tরুম ফ্রেম\tBingkai Room\tKhung phòng\tBingkai Bilik\tกรอบห้อง\tRoom Frame\tஅறை சட்டகம்\tإطار الغرفة
Title\tशीर्षक\tعنوان\tশিরোনাম\tJudul\tTiêu đề\tTajuk\tชื่อเรื่อง\tPamagat\tதலைப்பு\tالعنوان
Tag\tटैग\tٹیگ\tট্যাগ\tTag\tThẻ\tTag\tแท็ก\tTag\tகுறிச்சொல்\tعلامة
Insufficient props to participate in the draw. Go send event gifts or finish mission to get more lottery props!\tड्रॉ में भाग लेने के लिए पर्याप्त प्रॉप नहीं हैं। अधिक लॉटरी प्रॉप पाने के लिए इवेंट गिफ्ट भेजें या मिशन पूरा करें!\tড্রতে অংশ নেওয়ার জন্য পর্যাপ্ত প্রপ নেই। আরও লটারি প্রপ পেতে ইভেন্ট গিফট পাঠান অথবা মিশন সম্পূর্ণ করুন!\tقرعہ اندازی میں حصہ لینے کے لیے کافی پروپس نہیں ہیں۔ مزید لاٹری پروپس حاصل کرنے کے لیے ایونٹ گفٹس بھیجیں یا مشن مکمل کریں!\tProp tidak cukup untuk mengikuti undian. Kirim hadiah event atau selesaikan misi untuk mendapatkan lebih banyak prop undian!\tKhông đủ đạo cụ để tham gia quay thưởng. Hãy gửi quà sự kiện hoặc hoàn thành nhiệm vụ để nhận thêm đạo cụ quay thưởng!\tProp tidak mencukupi untuk menyertai cabutan. Hantar hadiah acara atau selesaikan misi untuk mendapatkan lebih banyak prop cabutan!\tไอเทมไม่เพียงพอสำหรับเข้าร่วมการจับรางวัล ส่งของขวัญกิจกรรมหรือทำภารกิจให้สำเร็จเพื่อรับไอเทมจับรางวัลเพิ่ม!\tKulang ang prop para makasali sa bunutan. Magpadala ng event gifts o kumpletuhin ang mission para makakuha ng mas maraming lottery prop!\tகுலுக்கலில் பங்கேற்க போதுமான பொருட்கள் இல்லை. மேலும் குலுக்கல் பொருட்களைப் பெற நிகழ்வுப் பரிசுகளை அனுப்புங்கள் அல்லது பணியை முடிக்கவும்!\tلا توجد أدوات كافية للمشاركة في السحب. أرسل هدايا الفعالية أو أكمل المهمة للحصول على المزيد من أدوات السحب!''';

void main() {
  group('TsvTableConverter', () {
    test('preserves empty quoted fields, astral Unicode and literal CRLF', () {
      final table = TsvTableConverter.parse(
        'A\tB\tC\r\n""\t"😀""quoted"\t"first\r\nsecond"',
      );
      expect(table.rows.last, ['', '😀"quoted', 'first\nsecond']);
      expect(
        TsvTableConverter.toMarkdown(table, firstRowIsHeader: true),
        '| A | B | C |\n| --- | --- | --- |\n|  | 😀\\"quoted | first<br>second |',
      );
    });

    test(
      'background parsing and generation preserve quoted Unicode cells',
      () async {
        final largeValue = '${'多语😀*|' * 12000}\nsecond line';
        final source = 'Name\tValue\nalpha\t"$largeValue"';
        final expected = TsvTableConverter.toMarkdown(
          TsvTableConverter.parse(source),
          firstRowIsHeader: true,
        );
        final table = await TsvTableConverter.parseAsync(source);
        expect(table.rows.last.last, largeValue);
        expect(
          await TsvTableConverter.generateMarkdown(
            source,
            firstRowIsHeader: true,
          ),
          expected,
        );
        expect(
          await TsvTableConverter.generateMarkdown(
            source,
            firstRowIsHeader: true,
            parsedTable: table,
          ),
          expected,
        );
      },
    );

    test('background parsing preserves format exceptions', () async {
      final source = 'Name\tValue\n"${'a' * (64 * 1024)}';
      await expectLater(
        TsvTableConverter.parseAsync(source),
        throwsA(
          isA<TsvTableFormatException>().having(
            (error) => error.recordNumber,
            'recordNumber',
            2,
          ),
        ),
      );
    });

    test('converts the supplied multilingual sample without losing cells', () {
      final table = TsvTableConverter.parse(_sample);
      final markdown = TsvTableConverter.toMarkdown(
        table,
        firstRowIsHeader: true,
      );

      expect(table.columnCount, 11);
      expect(table.rows.length - 1, 25);
      expect(table.rows.where((row) => row.first == 'Vehicle'), hasLength(2));
      expect(table.rows.last[1], startsWith('ड्रॉ में भाग लेने'));
      expect(table.rows.last[2], startsWith('ড্রতে অংশ নেওয়ার'));
      expect(table.rows.last[3], startsWith('قرعہ اندازی میں'));
      expect(
        markdown,
        contains('| 英文 | 印地 | 乌尔都 | 孟加拉 | ID | VI | MS | TH | FIL | TA | AR |'),
      );
      expect(markdown.split('\n'), hasLength(27));
      expect(markdown, contains('OK lang'));
      expect(markdown, contains('Haco'));
      expect(markdown, contains('சரி'));
      expect(markdown, contains('حسنا'));
    });

    test('normalizes line endings and preserves trailing empty cells', () {
      final table = TsvTableConverter.parse('A\tB\r\n1\t\r\n');

      expect(table.rows, [
        ['A', 'B'],
        ['1', ''],
      ]);
    });

    test(
      'joins unquoted multiline cells when following lines are continuations',
      () {
        final table = TsvTableConverter.parse(
          'Key\tEnglish\tHindi\tBengali\n'
          'topic.Rules\tFind every number\n'
          'Wrong tap?\tहर नंबर\n'
          'गलत टैप\tপ্রতিটি সংখ্যা\n'
          'পরের অংশ\n'
          'next\tPlay again\tHindi again\tBengali again',
        );

        expect(table.rows, [
          ['Key', 'English', 'Hindi', 'Bengali'],
          [
            'topic.Rules',
            'Find every number\nWrong tap?',
            'हर नंबर\nगलत टैप',
            'প্রতিটি সংখ্যা\nপরের অংশ',
          ],
          ['next', 'Play again', 'Hindi again', 'Bengali again'],
        ]);
      },
    );

    test('retains empty rows instead of silently removing them', () {
      expect(
        () => TsvTableConverter.parse('A\tB\n1\t2\n\n'),
        throwsA(
          isA<TsvTableFormatException>().having(
            (error) => error.recordNumber,
            'recordNumber',
            3,
          ),
        ),
      );
    });

    test('parses quoted tabs, newlines and doubled quotes', () {
      final table = TsvTableConverter.parse(
        'Name\tDescription\nalpha\t"Line one\nLine two\tand ""quotes"""',
      );

      expect(table.rows.last, ['alpha', 'Line one\nLine two\tand "quotes"']);
      final markdown = TsvTableConverter.toMarkdown(
        table,
        firstRowIsHeader: true,
      );
      expect(markdown, contains(r'Line one<br>Line two	and \"quotes\"'));
    });

    test('reports the logical record when column counts differ', () {
      expect(
        () => TsvTableConverter.parse('A\tB\n1\t2\n3'),
        throwsA(
          isA<TsvTableFormatException>()
              .having((error) => error.recordNumber, 'recordNumber', 3)
              .having((error) => error.message, 'message', contains('检测到 1 列')),
        ),
      );
    });

    test('reports an unclosed quoted field', () {
      expect(
        () => TsvTableConverter.parse('A\tB\n1\t"unfinished'),
        throwsA(
          isA<TsvTableFormatException>()
              .having((error) => error.recordNumber, 'recordNumber', 2)
              .having((error) => error.message, 'message', contains('未闭合')),
        ),
      );
    });

    test('preserves literal quotes in unquoted and quoted fields', () {
      final table = TsvTableConverter.parse(
        'Name\tText\nalpha\tClick the "Invite" button\n'
        'beta\t"She said "hello" today"',
      );

      expect(table.rows[1].last, 'Click the "Invite" button');
      expect(table.rows[2].last, 'She said "hello" today');
    });

    test('escapes literal Markdown punctuation and table separators', () {
      final table = TsvTableConverter.parse(
        'Name\tText\nalpha\t"a|b *bold* _x_ [label](url) \\\\path"',
      );
      final markdown = TsvTableConverter.toMarkdown(
        table,
        firstRowIsHeader: true,
      );

      expect(markdown, contains(r'a\|b'));
      expect(markdown, contains(r'\*bold\*'));
      expect(markdown, contains(r'\_x\_'));
      expect(markdown, contains(r'\[label\]\(url\)'));
      expect(markdown, contains(r'\\path'));
    });

    test('uses generated headers without dropping the first input record', () {
      final table = TsvTableConverter.parse('English\tHindi\nOK\tठीक');

      expect(
        TsvTableConverter.toMarkdown(table, firstRowIsHeader: false),
        '| 列 1 | 列 2 |\n| --- | --- |\n| English | Hindi |\n| OK | ठीक |',
      );
    });

    test('accepts a header-only table and rejects truly empty input', () {
      final table = TsvTableConverter.parse('A\tB\n');
      expect(
        TsvTableConverter.toMarkdown(table, firstRowIsHeader: true),
        '| A | B |\n| --- | --- |',
      );
      expect(
        () => TsvTableConverter.parse(''),
        throwsA(isA<TsvTableFormatException>()),
      );
    });
  });
}
