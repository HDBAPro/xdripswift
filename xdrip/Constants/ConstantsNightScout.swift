enum ConstantsNightScout {
    
    /// - default nightscout url
    /// - used in settings, when setting first time nightscout url
    static let defaultNightScoutUrl = "https://yoursitename.herokuapp.com"
    
    /// maximum number of days to upload
    static let maxBgReadingsDaysToUpload = TimeInterval(days: 7)
    
    /// there's al imit of 102400 bytes to upload to NightScout, this corresponds on average to 400 readings. Setting a lower maximum value to avoid to bypass this limit.
    static let maxReadingsToUpload = 300
    
    /// if the time between the last and last but one reading is less than minimiumTimeBetweenTwoReadingsInMinutes, then the last reading will not be uploaded - except if there's been a disconnect in between these two readings
    static let minimiumTimeBetweenTwoReadingsInMinutes = 4.75
    
    /// maximum amount of treatments to download
    ///
    /// keep amount to upload and download the same, becauwe while downloading we also check if it has id's for treatmententry's which are marked as not yet uploaded
    static let maxTreatmentsToUpOrDownload = 50

}
