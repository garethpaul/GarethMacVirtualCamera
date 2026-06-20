import CoreMedia

enum SampleTimestampValidator {
    static func strictlyAdvances(_ presentationTime: CMTime,
                                 after previousPresentationTime: CMTime?) -> Bool {
        guard presentationTime.isNumeric else {
            return false
        }

        guard let previousPresentationTime else {
            return true
        }

        guard previousPresentationTime.isNumeric else {
            return false
        }

        return CMTimeCompare(presentationTime, previousPresentationTime) > 0
    }
}
