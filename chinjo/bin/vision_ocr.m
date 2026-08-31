#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: vision_ocr IMAGE_LIST\n");
            return 2;
        }
        NSString *listPath = [NSString stringWithUTF8String:argv[1]];
        NSError *error = nil;
        NSString *list = [NSString stringWithContentsOfFile:listPath encoding:NSUTF8StringEncoding error:&error];
        if (!list) {
            fprintf(stderr, "cannot read list: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        for (NSString *path in [list componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (path.length == 0) continue;
            @autoreleasepool {
                NSString *output = [[path stringByReplacingOccurrencesOfString:@"/images/" withString:@"/vision_text/"]
                    stringByDeletingPathExtension];
                output = [output stringByAppendingPathExtension:@"txt"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:output]) continue;

                NSImage *source = [[NSImage alloc] initWithContentsOfFile:path];
                CGImageRef image = [source CGImageForProposedRect:NULL context:nil hints:nil];
                if (!image) {
                    fprintf(stderr, "cannot read image: %s\n", path.UTF8String);
                    continue;
                }
                VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
                request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
                request.recognitionLanguages = @[@"ja-JP", @"en-US"];
                request.usesLanguageCorrection = YES;
                VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
                error = nil;
                if (![handler performRequests:@[request] error:&error]) {
                    fprintf(stderr, "OCR failed: %s: %s\n", path.UTF8String,
                            error.localizedDescription.UTF8String);
                    continue;
                }
                NSArray<VNRecognizedTextObservation *> *results = [request.results sortedArrayUsingComparator:
                    ^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
                        CGFloat dy = CGRectGetMidY(a.boundingBox) - CGRectGetMidY(b.boundingBox);
                        if (fabs(dy) > 0.008) return dy > 0 ? NSOrderedAscending : NSOrderedDescending;
                        CGFloat dx = CGRectGetMinX(a.boundingBox) - CGRectGetMinX(b.boundingBox);
                        return dx < 0 ? NSOrderedAscending : (dx > 0 ? NSOrderedDescending : NSOrderedSame);
                    }];
                NSMutableArray<NSString *> *text = [NSMutableArray array];
                for (VNRecognizedTextObservation *observation in results) {
                    VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
                    if (candidate) [text addObject:candidate.string];
                }
                [[NSFileManager defaultManager] createDirectoryAtPath:[output stringByDeletingLastPathComponent]
                                           withIntermediateDirectories:YES attributes:nil error:&error];
                NSString *joined = [[text componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
                if (![joined writeToFile:output atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
                    fprintf(stderr, "write failed: %s: %s\n", output.UTF8String,
                            error.localizedDescription.UTF8String);
                    continue;
                }
                fprintf(stderr, "vision %s\n", path.UTF8String);
            }
        }
    }
    return 0;
}
