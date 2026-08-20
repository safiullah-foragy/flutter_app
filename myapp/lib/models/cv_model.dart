class CVFormData {
  // Personal Information
  String name;
  String fatherName;
  String motherName;
  String presentAddress;
  String permanentAddress;
  String dateOfBirth;
  String age;
  String gender;
  String maritalStatus;
  String nationality;
  String nid;
  String passport;
  String religion;
  
  // Contact Information
  String email;
  String phone;
  String alternatePhone;
  String linkedIn;
  String website;
  
  // Education - SSC
  String sscGpa;
  String sscSchool;
  String sscBoard;
  String sscYear;
  String sscGroup;
  
  // Education - HSC
  String hscGpa;
  String hscCollege;
  String hscBoard;
  String hscYear;
  String hscGroup;
  
  // Education - Graduation
  String graduationSubject;
  String graduationCgpa;
  String graduationInstitution;
  String graduationYear;
  String graduationDegree;
  
  // Professional
  bool currentJob;
  String currentJobTitle;
  String currentJobCompany;
  String currentJobDuration;
  String currentJobLocation;
  String currentJobResponsibilities;
  
  // Additional Information
  String skills;
  String languages;
  String hobbies;
  String certifications;
  String awards;
  String references;
  String objective;
  String summary;
  
  List<PreviousJob> previousJobs;
  String? photoPath;

  CVFormData({
    this.name = '',
    this.fatherName = '',
    this.motherName = '',
    this.presentAddress = '',
    this.permanentAddress = '',
    this.dateOfBirth = '',
    this.age = '',
    this.gender = '',
    this.maritalStatus = '',
    this.nationality = '',
    this.nid = '',
    this.passport = '',
    this.religion = '',
    this.email = '',
    this.phone = '',
    this.alternatePhone = '',
    this.linkedIn = '',
    this.website = '',
    this.sscGpa = '',
    this.sscSchool = '',
    this.sscBoard = '',
    this.sscYear = '',
    this.sscGroup = '',
    this.hscGpa = '',
    this.hscCollege = '',
    this.hscBoard = '',
    this.hscYear = '',
    this.hscGroup = '',
    this.graduationSubject = '',
    this.graduationCgpa = '',
    this.graduationInstitution = '',
    this.graduationYear = '',
    this.graduationDegree = '',
    this.currentJob = false,
    this.currentJobTitle = '',
    this.currentJobCompany = '',
    this.currentJobDuration = '',
    this.currentJobLocation = '',
    this.currentJobResponsibilities = '',
    this.skills = '',
    this.languages = '',
    this.hobbies = '',
    this.certifications = '',
    this.awards = '',
    this.references = '',
    this.objective = '',
    this.summary = '',
    this.previousJobs = const [],
    this.photoPath,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'fatherName': fatherName,
      'motherName': motherName,
      'presentAddress': presentAddress,
      'permanentAddress': permanentAddress,
      'dateOfBirth': dateOfBirth,
      'age': age,
      'gender': gender,
      'maritalStatus': maritalStatus,
      'nationality': nationality,
      'nid': nid,
      'passport': passport,
      'religion': religion,
      'email': email,
      'phone': phone,
      'alternatePhone': alternatePhone,
      'linkedIn': linkedIn,
      'website': website,
      'sscGpa': sscGpa,
      'sscSchool': sscSchool,
      'sscBoard': sscBoard,
      'sscYear': sscYear,
      'sscGroup': sscGroup,
      'hscGpa': hscGpa,
      'hscCollege': hscCollege,
      'hscBoard': hscBoard,
      'hscYear': hscYear,
      'hscGroup': hscGroup,
      'graduationSubject': graduationSubject,
      'graduationCgpa': graduationCgpa,
      'graduationInstitution': graduationInstitution,
      'graduationYear': graduationYear,
      'graduationDegree': graduationDegree,
      'currentJob': currentJob,
      'currentJobTitle': currentJobTitle,
      'currentJobCompany': currentJobCompany,
      'currentJobDuration': currentJobDuration,
      'currentJobLocation': currentJobLocation,
      'currentJobResponsibilities': currentJobResponsibilities,
      'skills': skills,
      'languages': languages,
      'hobbies': hobbies,
      'certifications': certifications,
      'awards': awards,
      'references': references,
      'objective': objective,
      'summary': summary,
    };
  }
}

class PreviousJob {
  String jobTitle;
  String jobCompany;
  String jobDuration;

  PreviousJob({
    required this.jobTitle,
    required this.jobCompany,
    required this.jobDuration,
  });

  Map<String, dynamic> toJson() {
    return {
      'jobTitle': jobTitle,
      'jobCompany': jobCompany,
      'jobDuration': jobDuration,
    };
  }
}

class CVTemplate {
  final int id;
  final String name;
  final String color;
  final String description;

  CVTemplate({
    required this.id,
    required this.name,
    required this.color,
    required this.description,
  });
}

class GeneratedCV {
  final int templateId;
  final String templateName;
  final CVFile pdf;
  final CVFile docx;

  GeneratedCV({
    required this.templateId,
    required this.templateName,
    required this.pdf,
    required this.docx,
  });

  factory GeneratedCV.fromJson(Map<String, dynamic> json) {
    return GeneratedCV(
      templateId: json['templateId'] ?? 0,
      templateName: json['templateName'] ?? '',
      pdf: CVFile.fromJson(json['pdf'] ?? {}),
      docx: CVFile.fromJson(json['docx'] ?? {}),
    );
  }
}

class CVFile {
  final String viewUrl;
  final String downloadUrl;
  final String filename;

  CVFile({
    required this.viewUrl,
    required this.downloadUrl,
    required this.filename,
  });

  factory CVFile.fromJson(Map<String, dynamic> json) {
    return CVFile(
      viewUrl: json['viewUrl'] ?? '',
      downloadUrl: json['downloadUrl'] ?? '',
      filename: json['filename'] ?? '',
    );
  }
}
