import 'package:flutter/material.dart';
import 'package:pos_printer_manager/pos_printer_manager.dart';
import 'package:pos_printer_manager_example/webview_helper.dart';
import 'package:webcontent_converter/webcontent_converter.dart' as webcontent_converter;
import 'demo.dart';
import 'service.dart';

class USBPrinterScreen extends StatefulWidget {
  @override
  _USBPrinterScreenState createState() => _USBPrinterScreenState();
}

class _USBPrinterScreenState extends State<USBPrinterScreen> {
  bool _isLoading = false;
  List<USBPrinter> _printers = [];
  USBPrinterManager? _manager;
  List<int> _data = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("USB Printer Screen"),
      ),
      body: ListView(
        children: [
          ..._printers
              .map((printer) => ListTile(
                    title: Text("${printer.name}"),
                    subtitle: Text("${printer.address}"),
                    leading: Icon(Icons.usb),
                    onTap: () => _connect(printer),
                    trailing: printer.connected 
                      ? IconButton(
                          icon: Icon(Icons.print),
                          onPressed: () => _testPrint(),
                        )
                      : null,
                    onLongPress: () {
                      _startPrinter();
                    },
                    selected: printer.connected,
                  ))
              .toList(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: _isLoading ? Icon(Icons.stop) : Icon(Icons.play_arrow),
        onPressed: _isLoading ? null : _scan,
      ),
    );
  }

  _scan() async {
    setState(() {
      _isLoading = true;
      _printers = [];
    });
    var printers = await USBPrinterManager.discover();
    setState(() {
      _isLoading = false;
      _printers = printers;
    });
  }

  _connect(USBPrinter printer) async {
    var paperSize = PaperSize.mm80;
    var profile = await CapabilityProfile.load();
    var manager = USBPrinterManager(printer, paperSize, profile);
    await manager.connect();
    setState(() {
      _manager = manager;
      printer.connected = true;
    });
  }

  _startPrinter() async {
    if (_data.isEmpty) {
      final content = Demo.getShortReceiptContent();

      var bytes = await webcontent_converter.WebcontentConverter.contentToImage(
        content: content,
        executablePath: WebViewHelper.executablePath(),
      );
      var service = ESCPrinterService(bytes);
      var data = await service.getBytes();
      if (mounted) setState(() => _data = data);
    }

    if (_manager != null) {
      print("isConnected ${_manager!.isConnected}");
      _manager!.writeBytes(_data, isDisconnect: false);
    }
  }

  Future<void> _testPrint() async {
    if (_manager == null) return;

    try {
      // Generate test receipt
      final profile = await CapabilityProfile.load();
      final generator = Generator(PaperSize.mm80, profile);
      List<int> bytes = [];

      // Print demo header
      bytes += generator.text('TEST PRINT',
          styles: PosStyles(
            align: PosAlign.center,
            height: PosTextSize.size2,
            width: PosTextSize.size2,
          ));
      bytes += generator.text('ESC POS Printer Test',
          styles: PosStyles(align: PosAlign.center));
      bytes += generator.text('--------------------------------',
          styles: PosStyles(align: PosAlign.center));

      // Print styles demo
      bytes += generator.text('NORMAL: The quick brown fox...');
      bytes += generator.text('BOLD: The quick brown fox...',
          styles: PosStyles(bold: true));
      bytes += generator.text('REVERSE: The quick brown fox...',
          styles: PosStyles(reverse: true));
      bytes += generator.text('UNDERLINED: The quick brown fox...',
          styles: PosStyles(underline: true));

      // Print alignments
      bytes += generator.text('LEFT ALIGN',
          styles: PosStyles(align: PosAlign.left));
      bytes += generator.text('CENTER ALIGN',
          styles: PosStyles(align: PosAlign.center));
      bytes += generator.text('RIGHT ALIGN',
          styles: PosStyles(align: PosAlign.right));

      // Print QR Code
      bytes += generator.qrcode('https://pub.dev/packages/esc_pos_utils_plus');

      // Print barcode
      final List<int> barData = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 4];
      bytes += generator.barcode(Barcode.upcA(barData));

      bytes += generator.feed(2);
      bytes += generator.cut();

      // Send to printer
      await _manager!.writeBytes(bytes, isDisconnect: false);
    } catch (e) {
      print('Error printing: $e');
    }
  }
}
